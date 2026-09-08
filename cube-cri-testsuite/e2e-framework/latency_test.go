package e2eframework

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/uuid"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
)

var (
	latencyCount     = flag.Int("latency-count", envInt("LATENCY_COUNT", 100), "total cube pause pods for latency test")
	latencyOutputDir = flag.String("latency-output-dir", envString("LATENCY_OUTPUT_DIR", ""), "result directory; empty creates a temporary directory")
)

const latencyBatchLabel = "cubesandbox.io/latency-batch"

type latencyPodResult struct {
	Name         string               `json:"name"`
	CreateStart  time.Time            `json:"createStart"`
	CreateReturn time.Time            `json:"createReturn"`
	Created      bool                 `json:"created"`
	Error        string               `json:"error,omitempty"`
	Observed     map[string]time.Time `json:"observed"`
	Server       map[string]time.Time `json:"server"`
	Metrics      map[string]float64   `json:"metrics"`
	LastPod      *corev1.Pod          `json:"lastPod,omitempty"`
}

type latencyMetric struct {
	Count int     `json:"count"`
	P50MS float64 `json:"p50Ms"`
	P95MS float64 `json:"p95Ms"`
	P99MS float64 `json:"p99Ms"`
	MinMS float64 `json:"minMs"`
	MaxMS float64 `json:"maxMs"`
}

type latencySummary struct {
	Run                   string                   `json:"run"`
	Namespace             string                   `json:"namespace"`
	Node                  string                   `json:"node"`
	Scheduler             string                   `json:"scheduler"`
	Image                 string                   `json:"image"`
	Count                 int                      `json:"count"`
	Parallelism           int                      `json:"parallelism"`
	Created               int                      `json:"created"`
	Scheduled             int                      `json:"scheduled"`
	Running               int                      `json:"running"`
	Ready                 int                      `json:"ready"`
	Error                 string                   `json:"error,omitempty"`
	FirstCreateStart      time.Time                `json:"firstCreateStart"`
	LastCreateReturn      time.Time                `json:"lastCreateReturn"`
	LastScheduledObserved time.Time                `json:"lastScheduledObserved"`
	LastReadyObserved     time.Time                `json:"lastReadyObserved"`
	Batch                 map[string]float64       `json:"batch"`
	Metrics               map[string]latencyMetric `json:"metrics"`
}

func assessConcurrentLatency(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	count := *latencyCount
	if count == 0 {
		count = *latencyConcurrency
	}
	if count < 1 || *latencyConcurrency < 1 || *latencyTimeout <= 0 {
		t.Fatal("latency-count and latency-concurrency must be positive; latency-timeout must be > 0")
	}
	parallelism := min(count, *latencyConcurrency)
	frameworkClient, err := cfg.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	restCfg := rest.CopyConfig(frameworkClient.RESTConfig())
	// 并发度由 worker 控制，避免 client-go 默认限流改变提交负载。
	restCfg.QPS, restCfg.RateLimiter = -1, nil
	client, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		t.Fatal(err)
	}
	ensureRuntimeClasses(ctx, t, client)
	node := resolvedCubeNode(ctx, t, client)
	batch := string(uuid.NewUUID())
	pods := make([]*corev1.Pod, count)
	for i := range pods {
		pod := podBase(t, cfg, "lat")
		pod.Name = fmt.Sprintf("cube-lat-%s-%04d", batch, i+1)
		pod.Labels[latencyBatchLabel] = batch
		pod.Spec = corev1.PodSpec{
			RuntimeClassName: stringPtr("cube"),
			SchedulerName:    corev1.DefaultSchedulerName,
			Affinity: &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
				RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{{MatchFields: []corev1.NodeSelectorRequirement{
						{Key: "metadata.name", Operator: corev1.NodeSelectorOpIn, Values: []string{node}},
					}}},
				},
			}},
			RestartPolicy:                 corev1.RestartPolicyNever,
			TerminationGracePeriodSeconds: int64Ptr(0),
			Containers:                    []corev1.Container{pauseContainer("main")},
		}
		pods[i] = pod
	}
	out := *latencyOutputDir
	if out == "" {
		out, err = os.MkdirTemp("", "cube-cri-latency-")
	} else {
		err = os.MkdirAll(out, 0755)
	}
	if err != nil {
		t.Fatal(err)
	}
	out, err = filepath.Abs(out)
	if err != nil {
		t.Fatal(err)
	}
	selector := latencyBatchLabel + "=" + batch
	defer cleanupLatencyPods(t, client, namespace(cfg), selector)
	t.Logf("batch=%s node=%s count=%d parallelism=%d image=%s timeout=%s output=%s", batch, node, count, parallelism, *cubeImage, *latencyTimeout, out)
	runCtx, cancel := context.WithTimeout(ctx, *latencyTimeout)
	defer cancel()
	results, runErr := measureLatencyBatch(runCtx, client, pods, parallelism, selector)
	summary := summarizeLatency(results)
	summary.Run, summary.Namespace, summary.Node, summary.Image = batch, namespace(cfg), node, *cubeImage
	summary.Scheduler = corev1.DefaultSchedulerName
	summary.Parallelism = parallelism
	if runErr == nil {
		for _, r := range results {
			if r.LastPod == nil || r.LastPod.Spec.NodeName != node || r.Observed["scheduled"].IsZero() {
				runErr = fmt.Errorf("pod %s was not observed scheduled to target node %s", r.Name, node)
				break
			}
		}
	}
	if runErr != nil {
		summary.Error = runErr.Error()
	}
	for _, artifact := range []struct {
		suffix string
		value  any
	}{{"pods.json", results}, {"summary.json", summary}} {
		data, err := json.MarshalIndent(artifact.value, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(out, batch+"."+artifact.suffix)
		if err := os.WriteFile(path, append(data, '\n'), 0644); err != nil {
			t.Fatal(err)
		}
		t.Logf("%s=%s", artifact.suffix, path)
	}
	encoded, _ := json.Marshal(summary)
	t.Logf("SUMMARY_JSON %s", encoded)
	for _, name := range sortedLatencyKeys(summary.Metrics) {
		m := summary.Metrics[name]
		t.Logf("%s: n=%d p50=%.3fms p95=%.3fms p99=%.3fms min=%.3fms max=%.3fms", name, m.Count, m.P50MS, m.P95MS, m.P99MS, m.MinMS, m.MaxMS)
	}
	for _, name := range sortedLatencyKeys(summary.Batch) {
		t.Logf("%s=%.3fms", name, summary.Batch[name])
	}
	if runErr != nil {
		for _, r := range results {
			if !r.Created || r.Observed["ready"].IsZero() {
				t.Logf("pod=%s error=%s last=%s", r.Name, r.Error, podSummary(r.LastPod))
			}
		}
		t.Fatalf("latency batch failed: created=%d/%d scheduled=%d/%d ready=%d/%d: %v", summary.Created, count, summary.Scheduled, count, summary.Ready, count, runErr)
	}
	return ctx
}

// Watch 在提交前建立；只使用事件到达时间，不用轮询或创建响应补造观测时间。
func measureLatencyBatch(ctx context.Context, client kubernetes.Interface, pods []*corev1.Pod, parallelism int, selector string) ([]latencyPodResult, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make([]latencyPodResult, len(pods))
	indices := make(map[string]int, len(pods))
	for i, p := range pods {
		results[i] = latencyPodResult{Name: p.Name, Observed: map[string]time.Time{}, Server: map[string]time.Time{}}
		indices[p.Name] = i
	}
	for _, p := range pods {
		if p.Spec.NodeName != "" {
			return results, fmt.Errorf("pod %s sets nodeName and would bypass the scheduler", p.Name)
		}
	}
	api := client.CoreV1().Pods(pods[0].Namespace)
	list, err := api.List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return results, fmt.Errorf("list before watch: %w", err)
	}
	if len(list.Items) != 0 {
		return results, fmt.Errorf("batch selector already has %d pods", len(list.Items))
	}
	w, err := api.Watch(ctx, metav1.ListOptions{LabelSelector: selector, ResourceVersion: list.ResourceVersion})
	if err != nil {
		return results, fmt.Errorf("start watch: %w", err)
	}
	defer w.Stop()
	var mu sync.Mutex
	var createErr error
	watchDone := make(chan error, 1)
	go func() {
		var watchErr error
		defer func() {
			if watchErr != nil {
				cancel()
			}
			watchDone <- watchErr
		}()
		ready := 0
		for ready < len(pods) {
			select {
			case <-ctx.Done():
				watchErr = ctx.Err()
				return
			case event, ok := <-w.ResultChan():
				observed := time.Now()
				if !ok {
					watchErr = fmt.Errorf("pod watch closed before all pods were Ready")
					return
				}
				if event.Type == watch.Error {
					watchErr = apierrors.FromObject(event.Object)
					return
				}
				pod, ok := event.Object.(*corev1.Pod)
				if !ok {
					continue
				}
				i, ok := indices[pod.Name]
				if !ok {
					continue
				}
				mu.Lock()
				r := &results[i]
				wasReady := !r.Observed["ready"].IsZero()
				observeLatencyPod(r, pod, observed)
				if !wasReady && !r.Observed["ready"].IsZero() {
					ready++
				}
				mu.Unlock()
				if event.Type == watch.Deleted || pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded {
					watchErr = fmt.Errorf("pod %s terminated before batch completed: phase=%s reason=%s message=%s", pod.Name, pod.Status.Phase, pod.Status.Reason, pod.Status.Message)
					return
				}
			}
		}
	}()
	jobs := make(chan int, len(pods))
	for i := range pods {
		jobs <- i
	}
	close(jobs)
	var workers sync.WaitGroup
	for worker := 0; worker < parallelism; worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := range jobs {
				if ctx.Err() != nil {
					return
				}
				start := time.Now()
				created, err := api.Create(ctx, pods[i], metav1.CreateOptions{})
				returned := time.Now()
				mu.Lock()
				r := &results[i]
				r.CreateStart, r.CreateReturn = start, returned
				if err != nil {
					r.Error = err.Error()
					if createErr == nil {
						createErr = fmt.Errorf("create %s: %w", r.Name, err)
					}
				} else {
					r.Created = true
					r.Server["creation_timestamp"] = created.CreationTimestamp.Time
				}
				mu.Unlock()
				if err != nil {
					cancel()
					return
				}
			}
		}()
	}
	workers.Wait()
	watchErr := <-watchDone
	return results, errors.Join(createErr, watchErr)
}

func observeLatencyPod(r *latencyPodResult, pod *corev1.Pod, now time.Time) {
	r.LastPod = pod
	first := func(key string) {
		if r.Observed[key].IsZero() {
			r.Observed[key] = now
		}
	}
	// 以绑定写入划分调度和节点侧路径，不等待 PodScheduled 条件上报。
	if pod.Spec.NodeName != "" {
		first("scheduled")
	}
	if pod.Status.Phase == corev1.PodRunning {
		first("running")
	}
	for _, c := range pod.Status.Conditions {
		if c.Status != corev1.ConditionTrue {
			continue
		}
		var key string
		switch c.Type {
		case corev1.PodScheduled:
			key = "scheduled"
		case corev1.ContainersReady:
			key = "containers_ready"
		case corev1.PodReady:
			key = "ready"
		default:
			continue
		}
		if key != "scheduled" {
			first(key)
		}
		if r.Server[key+"_transition"].IsZero() && !c.LastTransitionTime.IsZero() {
			r.Server[key+"_transition"] = c.LastTransitionTime.Time
		}
	}
	// 全部常规容器的最晚 startedAt，与 Pod Running/Ready 分开统计。
	if len(pod.Status.ContainerStatuses) != len(pod.Spec.Containers) || len(pod.Spec.Containers) == 0 {
		return
	}
	var started time.Time
	for _, c := range pod.Status.ContainerStatuses {
		if c.State.Running == nil || c.State.Running.StartedAt.IsZero() {
			return
		}
		if c.State.Running.StartedAt.After(started) {
			started = c.State.Running.StartedAt.Time
		}
	}
	if r.Server["containers_started"].IsZero() {
		r.Server["containers_started"] = started
	}
}

func summarizeLatency(results []latencyPodResult) latencySummary {
	s := latencySummary{Count: len(results), Metrics: map[string]latencyMetric{}, Batch: map[string]float64{}}
	values := map[string][]float64{}
	var lastRunning time.Time
	for i := range results {
		r := &results[i]
		r.Metrics = map[string]float64{}
		add := func(name string, start, end time.Time) {
			if start.IsZero() || end.IsZero() {
				return
			}
			value := float64(end.Sub(start)) / float64(time.Millisecond)
			r.Metrics[name] = value
			values[name] = append(values[name], value)
		}
		if !r.CreateStart.IsZero() && (s.FirstCreateStart.IsZero() || r.CreateStart.Before(s.FirstCreateStart)) {
			s.FirstCreateStart = r.CreateStart
		}
		if r.CreateReturn.After(s.LastCreateReturn) {
			s.LastCreateReturn = r.CreateReturn
		}
		if !r.Created {
			continue
		}
		s.Created++
		add("create_api_ms", r.CreateStart, r.CreateReturn)
		for _, stage := range []string{"scheduled", "running", "containers_ready", "ready"} {
			add("create_start_to_"+stage+"_observed_ms", r.CreateStart, r.Observed[stage])
			add("create_return_to_"+stage+"_observed_ms", r.CreateReturn, r.Observed[stage])
		}
		for _, stage := range []string{"running", "containers_ready", "ready"} {
			add("scheduled_to_"+stage+"_observed_ms", r.Observed["scheduled"], r.Observed[stage])
		}
		add("running_to_ready_observed_ms", r.Observed["running"], r.Observed["ready"])
		add("creation_timestamp_to_scheduled_transition_ms", r.Server["creation_timestamp"], r.Server["scheduled_transition"])
		for _, stage := range []string{"containers_started", "containers_ready_transition", "ready_transition"} {
			add("creation_timestamp_to_"+stage+"_ms", r.Server["creation_timestamp"], r.Server[stage])
			add("scheduled_transition_to_"+stage+"_ms", r.Server["scheduled_transition"], r.Server[stage])
		}
		if at := r.Observed["scheduled"]; !at.IsZero() {
			s.Scheduled++
			if at.After(s.LastScheduledObserved) {
				s.LastScheduledObserved = at
			}
		}
		if at := r.Observed["running"]; !at.IsZero() {
			s.Running++
			if at.After(lastRunning) {
				lastRunning = at
			}
		}
		if at := r.Observed["ready"]; !at.IsZero() {
			s.Ready++
			if at.After(s.LastReadyObserved) {
				s.LastReadyObserved = at
			}
		}
	}
	if s.Count > 0 && s.Created == s.Count {
		s.Batch["start_submit_to_all_submitted_ms"] = latencyMS(s.FirstCreateStart, s.LastCreateReturn)
		if s.Scheduled == s.Count {
			s.Batch["start_submit_to_all_scheduled_observed_ms"] = latencyMS(s.FirstCreateStart, s.LastScheduledObserved)
		}
		if s.Running == s.Count {
			s.Batch["start_submit_to_all_running_observed_ms"] = latencyMS(s.FirstCreateStart, lastRunning)
		}
		if s.Ready == s.Count {
			s.Batch["start_submit_to_all_ready_observed_ms"] = latencyMS(s.FirstCreateStart, s.LastReadyObserved)
			s.Batch["all_submitted_to_all_ready_observed_ms"] = latencyMS(s.LastCreateReturn, s.LastReadyObserved)
		}
	}
	for name, samples := range values {
		s.Metrics[name] = latencyPercentiles(samples)
	}
	return s
}

func latencyMS(start, end time.Time) float64 {
	return float64(end.Sub(start)) / float64(time.Millisecond)
}

func latencyPercentiles(values []float64) latencyMetric {
	if len(values) == 0 {
		return latencyMetric{}
	}
	values = append([]float64(nil), values...)
	sort.Float64s(values)
	pick := func(p int) float64 { return values[(len(values)*p+99)/100-1] }
	return latencyMetric{Count: len(values), P50MS: pick(50), P95MS: pick(95), P99MS: pick(99), MinMS: values[0], MaxMS: values[len(values)-1]}
}

func sortedLatencyKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func cleanupLatencyPods(t *testing.T, client kubernetes.Interface, ns, selector string) {
	t.Helper()
	if *keepPods {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), *cleanupTimeout)
	defer cancel()
	api := client.CoreV1().Pods(ns)
	if err := api.DeleteCollection(ctx, metav1.DeleteOptions{}, metav1.ListOptions{LabelSelector: selector}); err != nil {
		t.Errorf("delete latency pods: %v", err)
		return
	}
	if err := wait.PollUntilContextCancel(ctx, time.Second, true, func(ctx context.Context) (bool, error) {
		pods, err := api.List(ctx, metav1.ListOptions{LabelSelector: selector})
		if err != nil {
			return false, err
		}
		return len(pods.Items) == 0, nil
	}); err != nil {
		t.Errorf("wait for latency pod cleanup (%s): %v", selector, err)
	}
}
