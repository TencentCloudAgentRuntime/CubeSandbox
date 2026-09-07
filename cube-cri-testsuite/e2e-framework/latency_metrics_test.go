package e2eframework

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"
)

func TestLatencyPercentiles(t *testing.T) {
	values := make([]float64, 100)
	for i := range values {
		values[i] = float64(100-i) + 0.25
	}
	got := latencyPercentiles(values)
	want := latencyMetric{Count: 100, P50MS: 50.25, P95MS: 95.25, P99MS: 99.25, MinMS: 1.25, MaxMS: 100.25}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if values[0] != 100.25 {
		t.Fatal("percentiles changed input order")
	}
	if latencyPercentiles(nil).Count != 0 {
		t.Fatal("empty samples must not create a zero latency sample")
	}
	if got := latencyPercentiles([]float64{-0.5}); got.P99MS != -0.5 || got.Count != 1 {
		t.Fatalf("singleton: %+v", got)
	}
}

func TestLatencyObservationsAndPartialSummary(t *testing.T) {
	start := time.Now()
	r := latencyPodResult{Created: true, CreateStart: start, CreateReturn: start.Add(4 * time.Millisecond), Observed: map[string]time.Time{}, Server: map[string]time.Time{}}
	pod := &corev1.Pod{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "main"}}}, Status: corev1.PodStatus{
		Phase:      corev1.PodRunning,
		Conditions: []corev1.PodCondition{{Type: corev1.ContainersReady, Status: corev1.ConditionTrue}},
	}}
	observeLatencyPod(&r, pod, start.Add(time.Millisecond))
	if !r.Observed["ready"].IsZero() {
		t.Fatal("ContainersReady must not imply Pod Ready")
	}
	pod.Status.Conditions = append(pod.Status.Conditions, corev1.PodCondition{Type: corev1.PodReady, Status: corev1.ConditionTrue})
	observeLatencyPod(&r, pod, start.Add(2*time.Millisecond))
	observeLatencyPod(&r, pod, start.Add(10*time.Millisecond))
	results := []latencyPodResult{r, {Name: "failed", Error: "create failed"}}
	summary := summarizeLatency(results)
	if summary.Ready != 1 || summary.Created != 1 || len(summary.Batch) != 0 {
		t.Fatalf("partial batch reported as complete: %+v", summary)
	}
	if got := summary.Metrics["create_start_to_ready_observed_ms"]; got.Count != 1 || got.P50MS != 2 {
		t.Fatalf("first observation lost or failed pod counted: %+v", got)
	}
	if got := summary.Metrics["create_return_to_ready_observed_ms"].MinMS; got != -2 {
		t.Fatalf("watch may arrive before Create response; got %v", got)
	}
	if _, ok := summary.Metrics["creation_timestamp_to_containers_started_ms"]; ok {
		t.Fatal("missing server timestamp must not become zero latency")
	}
	if len(results[0].Metrics) == 0 {
		t.Fatal("per-pod metrics missing")
	}
}

func TestLatencyBatchWatch(t *testing.T) {
	for _, mode := range []string{"ready", "create-error", "watch-closed", "failed", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			client := fake.NewClientset()
			w := watch.NewRaceFreeFake()
			defer w.Stop()
			watchStarted := false
			client.PrependWatchReactor("pods", func(clienttesting.Action) (bool, watch.Interface, error) {
				watchStarted = true
				return true, w, nil
			})
			client.PrependReactor("create", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
				if !watchStarted {
					return true, nil, fmt.Errorf("create before watch")
				}
				if mode == "create-error" {
					return true, nil, fmt.Errorf("injected create failure")
				}
				p := action.(clienttesting.CreateAction).GetObject().(*corev1.Pod).DeepCopy()
				p.CreationTimestamp = metav1.Now()
				if mode == "ready" {
					p.Spec.NodeName = "cube-node"
					w.Modify(p.DeepCopy())
					p.Status.Phase = corev1.PodRunning
					p.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}
					w.Modify(p)
				}
				if mode == "watch-closed" {
					w.Stop()
				}
				if mode == "failed" {
					p.Status = corev1.PodStatus{Phase: corev1.PodFailed, Reason: "OutOfmemory", Message: "injected admission rejection"}
					w.Modify(p)
				}
				return true, p, nil
			})
			pods := []*corev1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "one", Namespace: "default"}}, {ObjectMeta: metav1.ObjectMeta{Name: "two", Namespace: "default"}}}
			timeout := 5 * time.Second
			if mode == "timeout" {
				timeout = 50 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			results, err := measureLatencyBatch(ctx, client, pods, 2, "batch=test")
			summary := summarizeLatency(results)
			if mode == "ready" {
				if err != nil || summary.Created != 2 || summary.Scheduled != 2 || summary.Ready != 2 {
					t.Fatalf("ready batch: summary=%+v err=%v", summary, err)
				}
			} else {
				if err == nil {
					t.Fatal("incomplete batch must fail")
				}
				if _, ok := summary.Batch["start_submit_to_all_ready_observed_ms"]; ok {
					t.Fatal("incomplete batch emitted all-ready latency")
				}
				if mode == "create-error" && !strings.Contains(err.Error(), "injected create failure") {
					t.Fatalf("lost create error: %v", err)
				}
				if mode == "failed" && !strings.Contains(err.Error(), "injected admission rejection") {
					t.Fatalf("lost pod failure reason: %v", err)
				}
			}
		})
	}
}

func TestLatencySchedulingStages(t *testing.T) {
	start := time.Now()
	r := latencyPodResult{Created: true, CreateStart: start, CreateReturn: start.Add(time.Millisecond),
		Observed: map[string]time.Time{}, Server: map[string]time.Time{"creation_timestamp": start}}
	pod := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodPending,
		Conditions: []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionFalse, Reason: "Unschedulable"}},
	}}
	observeLatencyPod(&r, pod, start.Add(2*time.Millisecond))
	if !r.Observed["scheduled"].IsZero() || !r.Server["scheduled_transition"].IsZero() {
		t.Fatal("unschedulable pod must not have a scheduling completion timestamp")
	}
	if s := summarizeLatency([]latencyPodResult{r}); s.Scheduled != 0 || s.Metrics["scheduled_to_ready_observed_ms"].Count != 0 {
		t.Fatalf("unscheduled pod contributed a scheduling sample: %+v", s)
	}
	pod.Spec.NodeName = "cube-node"
	observeLatencyPod(&r, pod, start.Add(3*time.Millisecond))
	pod.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: metav1.NewTime(start.Add(2 * time.Millisecond))}}
	observeLatencyPod(&r, pod, start.Add(4*time.Millisecond))
	pod.Status.Phase = corev1.PodRunning
	observeLatencyPod(&r, pod, start.Add(7*time.Millisecond))
	pod.Status.Conditions = append(pod.Status.Conditions, corev1.PodCondition{Type: corev1.PodReady, Status: corev1.ConditionTrue, LastTransitionTime: metav1.NewTime(start.Add(8 * time.Millisecond))})
	observeLatencyPod(&r, pod, start.Add(9*time.Millisecond))
	observeLatencyPod(&r, pod, start.Add(20*time.Millisecond))
	results := []latencyPodResult{r}
	s := summarizeLatency(results)
	if s.Scheduled != 1 || s.Batch["start_submit_to_all_scheduled_observed_ms"] != 3 {
		t.Fatalf("binding observation overwritten by later conditions: %+v", s)
	}
	for name, want := range map[string]float64{
		"create_start_to_scheduled_observed_ms":         3,
		"create_return_to_scheduled_observed_ms":        2,
		"scheduled_to_running_observed_ms":              4,
		"scheduled_to_ready_observed_ms":                6,
		"creation_timestamp_to_scheduled_transition_ms": 2,
		"scheduled_transition_to_ready_transition_ms":   6,
	} {
		if got := s.Metrics[name]; got.Count != 1 || got.P50MS != want {
			t.Errorf("%s: got %+v, want one sample of %v", name, got, want)
		}
	}
	m := results[0].Metrics
	if m["create_start_to_scheduled_observed_ms"]+m["scheduled_to_ready_observed_ms"] != m["create_start_to_ready_observed_ms"] {
		t.Fatal("per-pod scheduling and node-side durations must add up to end-to-end latency")
	}
}

func TestLatencyRejectsPreboundPods(t *testing.T) {
	client := fake.NewClientset()
	pods := []*corev1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "prebound", Namespace: "default"}, Spec: corev1.PodSpec{NodeName: "cube-node"}}}
	_, err := measureLatencyBatch(context.Background(), client, pods, 1, "batch=test")
	if err == nil || !strings.Contains(err.Error(), "bypass the scheduler") || len(client.Actions()) != 0 {
		t.Fatalf("prebound pod must be rejected before API calls: err=%v actions=%v", err, client.Actions())
	}
}
