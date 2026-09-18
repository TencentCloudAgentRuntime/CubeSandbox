package e2eframework

import (
	"context"
	"flag"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
	"sigs.k8s.io/e2e-framework/pkg/features"
)

const (
	cubeVMResourcesAnnotation = "cube.vmmres"
	bytesPerMiB               = int64(1024 * 1024)
)

var resizeTimeout = flag.Duration("resize-timeout", envDuration("RESIZE_TIMEOUT", 3*time.Minute), "maximum wait for an in-place resize to be actuated")
var resizeRestartContainerd = flag.Bool("resize-restart-containerd", false, "restart containerd on the cube node while validating Pod-level resize recovery")

type containerdRuntimeVersion struct {
	Major int
	Minor int
	Patch int
}

func (version containerdRuntimeVersion) supportsPodLevelResize() bool {
	return version.Major > 2 || version.Major == 2 && version.Minor >= 4
}

type guestResourceState struct {
	OnlineCPUs       int
	MemoryTotalBytes int64
	CPUQuota         int64
	CPUPeriod        int64
	MemoryMaxBytes   int64
}

func TestInPlaceResize(t *testing.T) {
	if *probeOnly {
		t.Skip("probe-only=true")
	}

	feature := features.New("cube-cri AGC-45 in-place resize").
		WithLabel("scope", "resize").
		Assess("container-level-cpu-memory-expand-shrink-all-containerd", assessContainerLevelResize).
		Assess("pod-level-cpu-memory-expand-shrink-containerd-2.4", assessPodLevelResize).
		Assess("pod-level-multicontainer-classic-init-aggregate-containerd-2.4", assessClassicInitAggregateResize).
		Assess("pod-level-resize-after-containerd-restart-containerd-2.4", assessPodLevelResizeAfterContainerdRestart).
		Assess("pod-level-exceeds-vm-max-boundary-containerd-2.4", assessPodLevelResizeBeyondVMMax).
		Feature()

	testEnv.Test(t, feature)
}

func assessContainerLevelResize(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	node, version := cubeNodeContainerdVersion(ctx, t, client)
	t.Logf("AGC-45 container-level contract: node=%s containerd=%s", node.Name, node.Status.NodeInfo.ContainerRuntimeVersion)

	pod := resizeCubePod(t, ctx, cfg, client, "resize-container", 1, 512, 2, 1024, nil,
		[]corev1.Container{resizeContainer("main", "1", "512Mi")})
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	ready := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	identity := captureContainerIdentity(ready)
	initial := waitGuestResourceState(ctx, t, cfg, client, pod, "main", func(state guestResourceState) bool {
		return state.OnlineCPUs == 1 && state.MemoryTotalBytes >= 384*bytesPerMiB
	})

	resizeContainerLimits(ctx, t, client, pod, map[string]corev1.ResourceRequirements{
		"main": resizeResources("2", "768Mi"),
	})
	waitContainerResourcesActuated(ctx, t, client, pod, map[string]corev1.ResourceRequirements{
		"main": resizeResources("2", "768Mi"),
	}, identity)
	grown := waitGuestResourceState(ctx, t, cfg, client, pod, "main", func(state guestResourceState) bool {
		return state.OnlineCPUs >= 2 && state.CPUQuota == 2*state.CPUPeriod && state.MemoryMaxBytes == 768*bytesPerMiB
	})
	if grown.MemoryTotalBytes < initial.MemoryTotalBytes+128*bytesPerMiB {
		t.Fatalf("container-level memory expansion was not visible in guest: initial=%+v grown=%+v", initial, grown)
	}

	resizeContainerLimits(ctx, t, client, pod, map[string]corev1.ResourceRequirements{
		"main": resizeResources("1", "512Mi"),
	})
	waitContainerResourcesActuated(ctx, t, client, pod, map[string]corev1.ResourceRequirements{
		"main": resizeResources("1", "512Mi"),
	}, identity)
	shrunk := waitGuestResourceState(ctx, t, cfg, client, pod, "main", func(state guestResourceState) bool {
		// Cube keeps hot-added vCPUs online as a physical high-water mark. The
		// CPU decrease is enforced by cgroup quota while memory is reclaimed by
		// ballooning.
		return state.OnlineCPUs >= 2 && state.CPUQuota == state.CPUPeriod && state.MemoryMaxBytes == 512*bytesPerMiB && state.MemoryTotalBytes <= grown.MemoryTotalBytes-128*bytesPerMiB
	})

	t.Logf("container-level resize passed for containerd %d.%d.%d: initial=%+v grown=%+v shrunk=%+v", version.Major, version.Minor, version.Patch, initial, grown, shrunk)
	return ctx
}

func assessPodLevelResize(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	requireContainerd24(ctx, t, client)
	podResources := resizeResources("1", "512Mi")
	pod := resizeCubePod(t, ctx, cfg, client, "resize-pod-level", 1, 512, 4, 2048, &podResources,
		[]corev1.Container{
			resizeContainer("one", "", ""),
			resizeContainer("two", "", ""),
		})
	createPodWithPodLevelResources(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	ready := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	identity := captureContainerIdentity(ready)
	initial := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		return state.OnlineCPUs == 1 && state.MemoryTotalBytes >= 384*bytesPerMiB
	})

	grownResources := resizeResources("2", "1Gi")
	resizePodLevelResources(ctx, t, client, pod, grownResources)
	waitPodLevelResourcesActuated(ctx, t, client, pod, grownResources, identity)
	grown := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		return state.OnlineCPUs == 2 && leafCPUAllowsPodLimit(state, 2) && leafMemoryAllowsPodLimit(state, 1024*bytesPerMiB) && state.MemoryTotalBytes >= initial.MemoryTotalBytes+256*bytesPerMiB
	})

	shrunkResources := resizeResources("1", "512Mi")
	resizePodLevelResources(ctx, t, client, pod, shrunkResources)
	waitPodLevelResourcesActuated(ctx, t, client, pod, shrunkResources, identity)
	shrunk := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		return state.OnlineCPUs == 2 && leafCPUAllowsPodLimit(state, 1) && leafMemoryAllowsPodLimit(state, 512*bytesPerMiB) && state.MemoryTotalBytes <= grown.MemoryTotalBytes-256*bytesPerMiB
	})

	t.Logf("containerd 2.4+ pod-level resize passed through SandboxService.UpdateSandbox: initial=%+v grown=%+v shrunk=%+v", initial, grown, shrunk)
	return ctx
}

func assessClassicInitAggregateResize(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	requireContainerd24(ctx, t, client)
	pod := resizeCubePod(t, ctx, cfg, client, "resize-init-aggregate", 3, 2048, 4, 3072, nil,
		[]corev1.Container{
			resizeContainer("one", "500m", "256Mi"),
			resizeContainer("two", "500m", "256Mi"),
		})
	pod.Spec.InitContainers = []corev1.Container{resizeContainer("classic-init", "3", "2Gi", func(c *corev1.Container) {
		c.Command = []string{"/bin/sh", "-c", "echo classic-init-complete"}
	})}
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	ready := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	identity := captureContainerIdentity(ready)
	initial := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		return state.OnlineCPUs == 3 && state.MemoryTotalBytes >= 1536*bytesPerMiB
	})

	high := map[string]corev1.ResourceRequirements{
		"one": resizeResources("2", "1280Mi"),
		"two": resizeResources("2", "1280Mi"),
	}
	resizeContainerLimits(ctx, t, client, pod, high)
	waitContainerResourcesActuated(ctx, t, client, pod, high, identity)
	grown := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		return state.OnlineCPUs == 4 && state.MemoryTotalBytes >= initial.MemoryTotalBytes+256*bytesPerMiB
	})

	low := map[string]corev1.ResourceRequirements{
		"one": resizeResources("500m", "256Mi"),
		"two": resizeResources("500m", "256Mi"),
	}
	resizeContainerLimits(ctx, t, client, pod, low)
	waitContainerResourcesActuated(ctx, t, client, pod, low, identity)
	settled := waitGuestResourceState(ctx, t, cfg, client, pod, "one", func(state guestResourceState) bool {
		// The app containers total 1 vCPU/512Mi here, but the completed classic
		// init container keeps the Kubernetes sandbox aggregate at 3 vCPU/2Gi.
		// Physical CPUs remain at their 4-vCPU high-water mark; available memory
		// must settle near the 2Gi init peak rather than the active-container sum.
		return state.OnlineCPUs == 4 && state.MemoryTotalBytes <= grown.MemoryTotalBytes-128*bytesPerMiB && state.MemoryTotalBytes >= initial.MemoryTotalBytes-128*bytesPerMiB
	})

	t.Logf("containerd 2.4+ classic-init aggregate preserved after multi-container shrink: initial=%+v grown=%+v settled=%+v", initial, grown, settled)
	return ctx
}

func assessPodLevelResizeAfterContainerdRestart(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	if !*resizeRestartContainerd {
		t.Skip("set --resize-restart-containerd to run the disruptive containerd restart assessment")
	}
	client := clientset(t, cfg)
	node := requireContainerd24(ctx, t, client)
	initialResources := resizeResources("1", "512Mi")
	pod := resizeCubePod(t, ctx, cfg, client, "resize-runtime-restart", 1, 512, 2, 1024, &initialResources,
		[]corev1.Container{resizeContainer("main", "", "")})
	createPodWithPodLevelResources(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	ready := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	identity := captureContainerIdentity(ready)
	initial := waitGuestResourceState(ctx, t, cfg, client, pod, "main", func(state guestResourceState) bool {
		return state.OnlineCPUs == 1 && state.MemoryTotalBytes >= 384*bytesPerMiB
	})

	restartContainerdAndWait(ctx, t, client, node.Name)
	recovered := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	for name, before := range identity {
		status := containerStatusByName(recovered, name)
		if status == nil || before != fmt.Sprintf("%s/%d", status.ContainerID, status.RestartCount) {
			t.Fatalf("container identity changed across containerd restart: container=%s before=%s after=%v", name, before, status)
		}
	}

	grownResources := resizeResources("2", "1Gi")
	resizePodLevelResourcesAfterRestart(ctx, t, client, pod, grownResources)
	waitPodLevelResourcesActuated(ctx, t, client, pod, grownResources, identity)
	grown := waitGuestResourceState(ctx, t, cfg, client, pod, "main", func(state guestResourceState) bool {
		return state.OnlineCPUs == 2 && leafCPUAllowsPodLimit(state, 2) && leafMemoryAllowsPodLimit(state, 1024*bytesPerMiB) && state.MemoryTotalBytes >= initial.MemoryTotalBytes+256*bytesPerMiB
	})

	t.Logf("Pod-level resize recovered after containerd restart without container restart: initial=%+v grown=%+v", initial, grown)
	return ctx
}

func assessPodLevelResizeBeyondVMMax(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	requireContainerd24(ctx, t, client)
	initialResources := resizeResources("1", "512Mi")
	pod := resizeCubePod(t, ctx, cfg, client, "resize-over-max", 1, 512, 2, 1024, &initialResources,
		[]corev1.Container{resizeContainer("main", "", "")})
	createPodWithPodLevelResources(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)
	waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)

	before := readGuestResourceStateRequired(ctx, t, cfg, pod, "main")
	overMax := resizeResources("3", "1536Mi")
	resizePodLevelResources(ctx, t, client, pod, overMax)
	waitForResizeBoundary(ctx, t, cfg, client, pod, "main", before)
	state := readGuestResourceStateRequired(ctx, t, cfg, pod, "main")
	if !guestResourceStateUnchanged(before, state) {
		t.Fatalf("resize beyond cube.vmmres maximum was partially applied: before=%+v after=%+v", before, state)
	}

	got, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get over-max pod: %v", err)
	}
	if got.Spec.Resources == nil || !resourceRequirementsEqual(*got.Spec.Resources, overMax) {
		t.Fatalf("over-max resize request was not retained in Pod spec: got=%v want=%v", got.Spec.Resources, overMax)
	}
	if condition := resizeErrorCondition(got); condition != nil {
		t.Logf("resize beyond VM max surfaced by kubelet: reason=%s message=%q", condition.Reason, condition.Message)
	} else {
		if got.Status.Resources != nil && resourceRequirementsEqual(*got.Status.Resources, overMax) {
			t.Fatalf("kubelet reported an over-max resize as actuated while guest remained bounded: status.resources=%v guest=%+v", got.Status.Resources, state)
		}
		// UpdatePodSandboxResources is best-effort in kubelet. The shim error
		// may therefore be absent from Pod status; unchanged guest topology is
		// the capability-boundary evidence in that case.
		t.Logf("resize beyond VM max was rejected by CubeShim but not surfaced as a Pod resize condition; guest remained bounded: %+v", state)
	}
	return ctx
}

func resizeCubePod(t *testing.T, ctx context.Context, cfg *envconf.Config, client *kubernetes.Clientset, suffix string, cpu, memoryMiB, maxCPU, maxMemoryMiB int64, podResources *corev1.ResourceRequirements, containers []corev1.Container) *corev1.Pod {
	pod := cubePod(t, ctx, cfg, client, suffix, corev1.PodSpec{
		RestartPolicy: corev1.RestartPolicyNever,
		Containers:    containers,
		Resources:     podResources,
	})
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
	pod.Annotations[cubeVMResourcesAnnotation] = fmt.Sprintf(`{"cpu":%d,"memory":%d,"max_cpu":%d,"max_memory":%d}`, cpu, memoryMiB, maxCPU, maxMemoryMiB)
	return pod
}

func resizeContainer(name, cpu, memory string, opts ...func(*corev1.Container)) corev1.Container {
	c := noResourceContainer(name, []string{"/bin/sh", "-c", "sleep 3600"})
	if cpu != "" || memory != "" {
		c.Resources = resizeResources(cpu, memory)
	}
	c.ResizePolicy = []corev1.ContainerResizePolicy{
		{ResourceName: corev1.ResourceCPU, RestartPolicy: corev1.NotRequired},
		{ResourceName: corev1.ResourceMemory, RestartPolicy: corev1.NotRequired},
	}
	for _, opt := range opts {
		opt(&c)
	}
	return c
}

func resizeResources(cpu, memory string) corev1.ResourceRequirements {
	resources := corev1.ResourceRequirements{Requests: corev1.ResourceList{}, Limits: corev1.ResourceList{}}
	if cpu != "" {
		quantity := resource.MustParse(cpu)
		resources.Requests[corev1.ResourceCPU] = quantity
		resources.Limits[corev1.ResourceCPU] = quantity
	}
	if memory != "" {
		quantity := resource.MustParse(memory)
		resources.Requests[corev1.ResourceMemory] = quantity
		resources.Limits[corev1.ResourceMemory] = quantity
	}
	return resources
}

func createPodWithPodLevelResources(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod) {
	t.Helper()
	if err := createPodErr(ctx, client, pod); err != nil {
		message := strings.ToLower(err.Error())
		if strings.Contains(message, "podlevelresources") || strings.Contains(message, "pod-level resources") || strings.Contains(message, "unknown field") {
			t.Skipf("cluster does not enable PodLevelResources/InPlacePodLevelResourcesVerticalScaling: %v", err)
		}
		t.Fatal(err)
	}
}

func resizeContainerLimits(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod, desired map[string]corev1.ResourceRequirements) {
	t.Helper()
	current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get pod before container resize: %v", err)
	}
	for i := range current.Spec.Containers {
		resources, ok := desired[current.Spec.Containers[i].Name]
		if ok {
			setResizableResources(&current.Spec.Containers[i].Resources, resources)
		}
	}
	if _, err := client.CoreV1().Pods(pod.Namespace).UpdateResize(ctx, pod.Name, current, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("resize container resources for pod %s/%s: %v", pod.Namespace, pod.Name, err)
	}
}

func resizePodLevelResources(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod, desired corev1.ResourceRequirements) {
	t.Helper()
	current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get pod before pod-level resize: %v", err)
	}
	if current.Spec.Resources == nil {
		current.Spec.Resources = &corev1.ResourceRequirements{}
	}
	setResizableResources(current.Spec.Resources, desired)
	var updated corev1.Pod
	err = client.CoreV1().RESTClient().
		Put().
		Namespace(pod.Namespace).
		Resource("pods").
		Name(pod.Name).
		SubResource("resize").
		Body(current).
		Do(ctx).
		Into(&updated)
	if err != nil {
		message := strings.ToLower(err.Error())
		if strings.Contains(message, "inplacepodlevelresourcesverticalscaling") || strings.Contains(message, "pod-level resources") && strings.Contains(message, "disabled") {
			t.Skipf("cluster does not enable InPlacePodLevelResourcesVerticalScaling: %v", err)
		}
		t.Fatalf("resize pod-level resources for pod %s/%s: %v", pod.Namespace, pod.Name, err)
	}
	if updated.Generation <= current.Generation {
		t.Fatalf("pod-level resize did not advance Pod generation: before=%d after=%d", current.Generation, updated.Generation)
	}
}

func resizePodLevelResourcesAfterRestart(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod, desired corev1.ResourceRequirements) {
	t.Helper()
	var lastErr error
	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, minDuration(*resizeTimeout, 2*time.Minute), true, func(ctx context.Context) (bool, error) {
		current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			lastErr = err
			return false, nil
		}
		if current.Spec.Resources == nil {
			current.Spec.Resources = &corev1.ResourceRequirements{}
		}
		setResizableResources(current.Spec.Resources, desired)
		var updated corev1.Pod
		err = client.CoreV1().RESTClient().
			Put().
			Namespace(pod.Namespace).
			Resource("pods").
			Name(pod.Name).
			SubResource("resize").
			Body(current).
			Do(ctx).
			Into(&updated)
		if err == nil {
			if updated.Generation <= current.Generation {
				return false, fmt.Errorf("pod-level resize did not advance Pod generation after runtime restart: before=%d after=%d", current.Generation, updated.Generation)
			}
			return true, nil
		}
		lastErr = err
		message := strings.ToLower(err.Error())
		if strings.Contains(message, "pod update requires features") && strings.Contains(message, "not available on node") {
			return false, nil
		}
		return false, err
	})
	if err != nil {
		t.Fatalf("pod-level resize was not accepted after containerd restart: lastErr=%v: %v", lastErr, err)
	}
}

func captureContainerIdentity(pod *corev1.Pod) map[string]string {
	identity := make(map[string]string, len(pod.Status.ContainerStatuses))
	for _, status := range pod.Status.ContainerStatuses {
		identity[status.Name] = fmt.Sprintf("%s/%d", status.ContainerID, status.RestartCount)
	}
	return identity
}

func waitContainerResourcesActuated(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod, desired map[string]corev1.ResourceRequirements, identity map[string]string) *corev1.Pod {
	t.Helper()
	var got *corev1.Pod
	var last string
	err := wait.PollUntilContextTimeout(ctx, time.Second, *resizeTimeout, true, func(ctx context.Context) (bool, error) {
		current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		got = current
		if condition := resizeErrorCondition(current); condition != nil {
			return false, fmt.Errorf("resize failed: reason=%s message=%q", condition.Reason, condition.Message)
		}
		for name, resources := range desired {
			status := containerStatusByName(current, name)
			if status == nil || status.Resources == nil || !resourceRequirementsEqual(*status.Resources, resources) {
				last = fmt.Sprintf("container=%s statusResources=%v desired=%v", name, statusResources(status), resources)
				return false, nil
			}
			if identity[name] != fmt.Sprintf("%s/%d", status.ContainerID, status.RestartCount) {
				return false, fmt.Errorf("container %s restarted during NotRequired resize: before=%s after=%s/%d", name, identity[name], status.ContainerID, status.RestartCount)
			}
		}
		if hasActiveResizeCondition(current) {
			last = "PodResizePending/PodResizeInProgress is still active"
			return false, nil
		}
		return true, nil
	})
	if err != nil {
		t.Fatalf("container resources were not actuated within %s: %v; last=%s; %s; events=%s", *resizeTimeout, err, last, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	return got
}

func waitPodLevelResourcesActuated(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod, desired corev1.ResourceRequirements, identity map[string]string) *corev1.Pod {
	t.Helper()
	overhead := corev1.ResourceList{}
	if pod.Spec.RuntimeClassName != nil {
		runtimeClass, err := client.NodeV1().RuntimeClasses().Get(ctx, *pod.Spec.RuntimeClassName, metav1.GetOptions{})
		if err != nil {
			t.Fatalf("get RuntimeClass %q overhead: %v", *pod.Spec.RuntimeClassName, err)
		}
		if runtimeClass.Overhead != nil {
			overhead = runtimeClass.Overhead.PodFixed
		}
	}
	expectedAllocated := addResourceLists(desired.Requests, overhead)
	expectedStatusLimits := addResourceLists(desired.Limits, overhead)
	var got *corev1.Pod
	var last string
	err := wait.PollUntilContextTimeout(ctx, time.Second, *resizeTimeout, true, func(ctx context.Context) (bool, error) {
		current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		got = current
		if condition := resizeErrorCondition(current); condition != nil {
			return false, fmt.Errorf("pod-level resize failed: reason=%s message=%q", condition.Reason, condition.Message)
		}
		if current.Spec.Resources == nil || !resourceRequirementsEqual(*current.Spec.Resources, desired) {
			last = fmt.Sprintf("spec.resources=%v desired=%v", current.Spec.Resources, desired)
			return false, nil
		}
		if !resourceListEqual(current.Status.AllocatedResources, expectedAllocated) {
			last = fmt.Sprintf("status.allocatedResources=%v expected=%v", current.Status.AllocatedResources, expectedAllocated)
			return false, nil
		}
		if current.Status.Resources == nil || !resourceListEqual(current.Status.Resources.Limits, expectedStatusLimits) {
			last = fmt.Sprintf("status.resources.limits=%v expected=%v", current.Status.Resources, expectedStatusLimits)
			return false, nil
		}
		for _, status := range current.Status.ContainerStatuses {
			if identity[status.Name] != fmt.Sprintf("%s/%d", status.ContainerID, status.RestartCount) {
				return false, fmt.Errorf("container %s restarted during pod-level NotRequired resize: before=%s after=%s/%d", status.Name, identity[status.Name], status.ContainerID, status.RestartCount)
			}
		}
		if hasActiveResizeCondition(current) {
			last = "PodResizePending/PodResizeInProgress is still active"
			return false, nil
		}
		return true, nil
	})
	if err != nil {
		t.Fatalf("pod-level resources were not actuated within %s: %v; last=%s; %s; events=%s", *resizeTimeout, err, last, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	return got
}

func resourceRequirementsEqual(got, want corev1.ResourceRequirements) bool {
	return resourceListEqual(got.Requests, want.Requests) && resourceListEqual(got.Limits, want.Limits)
}

func setResizableResources(target *corev1.ResourceRequirements, desired corev1.ResourceRequirements) {
	if target.Requests == nil {
		target.Requests = corev1.ResourceList{}
	}
	if target.Limits == nil {
		target.Limits = corev1.ResourceList{}
	}
	for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		if quantity, ok := desired.Requests[name]; ok {
			target.Requests[name] = quantity
		} else {
			delete(target.Requests, name)
		}
		if quantity, ok := desired.Limits[name]; ok {
			target.Limits[name] = quantity
		} else {
			delete(target.Limits, name)
		}
	}
}

func resourceListEqual(got, want corev1.ResourceList) bool {
	for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		gotQuantity, gotOK := got[name]
		wantQuantity, wantOK := want[name]
		if gotOK != wantOK || (gotOK && gotQuantity.Cmp(wantQuantity) != 0) {
			return false
		}
	}
	return true
}

func addResourceLists(base, extra corev1.ResourceList) corev1.ResourceList {
	result := corev1.ResourceList{}
	for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		quantity, ok := base[name]
		if !ok {
			continue
		}
		quantity = quantity.DeepCopy()
		if overhead, ok := extra[name]; ok {
			quantity.Add(overhead)
		}
		result[name] = quantity
	}
	return result
}

func leafCPUAllowsPodLimit(state guestResourceState, cores int64) bool {
	return state.CPUQuota == -1 || state.CPUPeriod > 0 && state.CPUQuota == cores*state.CPUPeriod
}

func leafMemoryAllowsPodLimit(state guestResourceState, bytes int64) bool {
	return state.MemoryMaxBytes == -1 || state.MemoryMaxBytes == bytes
}

func containerStatusByName(pod *corev1.Pod, name string) *corev1.ContainerStatus {
	for i := range pod.Status.ContainerStatuses {
		if pod.Status.ContainerStatuses[i].Name == name {
			return &pod.Status.ContainerStatuses[i]
		}
	}
	return nil
}

func statusResources(status *corev1.ContainerStatus) any {
	if status == nil {
		return nil
	}
	return status.Resources
}

func hasActiveResizeCondition(pod *corev1.Pod) bool {
	for _, condition := range pod.Status.Conditions {
		if (condition.Type == corev1.PodResizePending || condition.Type == corev1.PodResizeInProgress) && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func resizeErrorCondition(pod *corev1.Pod) *corev1.PodCondition {
	if pod == nil {
		return nil
	}
	for i := range pod.Status.Conditions {
		condition := &pod.Status.Conditions[i]
		failedType := condition.Type == corev1.PodResizeInProgress || condition.Type == corev1.PodResizePending
		failedReason := strings.EqualFold(condition.Reason, corev1.PodReasonError) || strings.EqualFold(condition.Reason, "Infeasible")
		if failedType && condition.Status == corev1.ConditionTrue && failedReason {
			return condition
		}
	}
	return nil
}

func waitForResizeBoundary(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, pod *corev1.Pod, container string, before guestResourceState) {
	t.Helper()
	var got *corev1.Pod
	var state guestResourceState
	var lastErr error
	started := time.Now()
	err := wait.PollUntilContextTimeout(ctx, time.Second, minDuration(*resizeTimeout, 30*time.Second), true, func(ctx context.Context) (bool, error) {
		current, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		got = current
		if resizeErrorCondition(current) != nil {
			return true, nil
		}
		state, lastErr = readGuestResourceState(ctx, t, cfg, pod, container)
		if lastErr != nil {
			return false, nil
		}
		bounded := guestResourceStateUnchanged(before, state)
		return bounded && time.Since(started) >= 15*time.Second, nil
	})
	if err != nil {
		t.Fatalf("resize beyond VM maximum did not converge to an error or remain bounded: state=%+v err=%v; %s; events=%s", state, lastErr, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
}

func guestResourceStateUnchanged(before, after guestResourceState) bool {
	memoryDelta := after.MemoryTotalBytes - before.MemoryTotalBytes
	if memoryDelta < 0 {
		memoryDelta = -memoryDelta
	}
	return after.OnlineCPUs == before.OnlineCPUs &&
		after.CPUQuota == before.CPUQuota &&
		after.CPUPeriod == before.CPUPeriod &&
		after.MemoryMaxBytes == before.MemoryMaxBytes &&
		memoryDelta <= 64*bytesPerMiB
}

var systemdTimestampPattern = regexp.MustCompile(`(?m)^([0-9]+)$`)

func restartContainerdAndWait(ctx context.Context, t *testing.T, client *kubernetes.Clientset, nodeName string) {
	t.Helper()
	before := waitContainerdActiveTimestamp(ctx, t, nodeName)
	unit := fmt.Sprintf("agc45-containerd-restart-%d", time.Now().UnixNano())
	commandCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	output, commandErr := exec.CommandContext(commandCtx, "kubectl", "node-shell", nodeName, "--",
		"systemd-run", "--unit", unit, "--collect", "/bin/systemctl", "restart", "containerd").CombinedOutput()
	cancel()
	if commandErr != nil && !strings.Contains(string(output), "Running as unit") {
		// The command tears down the CRI transport used by node-shell itself,
		// so attach/log streaming can fail after systemd accepted the unit.
		// The active timestamp below is the authoritative completion signal.
		t.Logf("containerd restart command transport closed; verifying timestamp: node=%s err=%v output=%s", nodeName, commandErr, output)
	}

	var lastTimestamp uint64
	var lastErr error
	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, minDuration(*resizeTimeout, 2*time.Minute), true, func(ctx context.Context) (bool, error) {
		lastTimestamp, lastErr = containerdActiveTimestamp(ctx, nodeName)
		if lastErr != nil || lastTimestamp <= before {
			return false, nil
		}
		node, getErr := client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if getErr != nil {
			lastErr = getErr
			return false, nil
		}
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady {
				return condition.Status == corev1.ConditionTrue, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("containerd did not recover after restart within timeout: before=%d after=%d lastErr=%v: %v", before, lastTimestamp, lastErr, err)
	}
}

func waitContainerdActiveTimestamp(ctx context.Context, t *testing.T, nodeName string) uint64 {
	t.Helper()
	var timestamp uint64
	var lastErr error
	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, 30*time.Second, true, func(ctx context.Context) (bool, error) {
		timestamp, lastErr = containerdActiveTimestamp(ctx, nodeName)
		return lastErr == nil && timestamp > 0, nil
	})
	if err != nil {
		t.Fatalf("read containerd start timestamp on node %s: lastErr=%v: %v", nodeName, lastErr, err)
	}
	return timestamp
}

func containerdActiveTimestamp(ctx context.Context, nodeName string) (uint64, error) {
	commandCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	output, err := exec.CommandContext(commandCtx, "kubectl", "node-shell", nodeName, "--",
		"systemctl", "show", "containerd", "--property", "ActiveEnterTimestampMonotonic", "--value").CombinedOutput()
	if err != nil {
		return 0, fmt.Errorf("inspect containerd service on node %s: %w: %s", nodeName, err, output)
	}
	matches := systemdTimestampPattern.FindAllStringSubmatch(string(output), -1)
	if len(matches) == 0 {
		return 0, fmt.Errorf("containerd start timestamp missing from node-shell output: %q", output)
	}
	value, err := strconv.ParseUint(matches[len(matches)-1][1], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse containerd start timestamp %q: %w", matches[len(matches)-1][1], err)
	}
	return value, nil
}

func waitGuestResourceState(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, pod *corev1.Pod, container string, accept func(guestResourceState) bool) guestResourceState {
	t.Helper()
	var state guestResourceState
	var lastErr error
	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, *resizeTimeout, true, func(ctx context.Context) (bool, error) {
		state, lastErr = readGuestResourceState(ctx, t, cfg, pod, container)
		if lastErr != nil {
			return false, nil
		}
		return accept(state), nil
	})
	if err != nil {
		got, _ := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		t.Fatalf("guest resources did not converge within %s: state=%+v err=%v; %s; events=%s", *resizeTimeout, state, lastErr, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	return state
}

func readGuestResourceState(ctx context.Context, t *testing.T, cfg *envconf.Config, pod *corev1.Pod, container string) (guestResourceState, error) {
	t.Helper()
	command := []string{"/bin/sh", "-c", `set -eu
printf 'cpu_online='; cat /sys/devices/system/cpu/online
awk '/^MemTotal:/ {print "mem_total_kb=" $2}' /proc/meminfo
printf 'cpu_max='; cat /sys/fs/cgroup/cpu.max
printf 'memory_max='; cat /sys/fs/cgroup/memory.max`}
	podExecCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	stdout, stderr, podErr := execInPod(podExecCtx, cfg, pod.Namespace, pod.Name, container, command)
	cancel()
	if podErr != nil {
		nodeStdout, nodeErr := execGuestResourceStateFromNode(ctx, cfg, pod, container, command)
		if nodeErr != nil {
			return guestResourceState{}, fmt.Errorf("inspect guest resources through Pod exec: %w; stdout=%q stderr=%q; node crictl: %v", podErr, stdout, stderr, nodeErr)
		}
		stdout = nodeStdout
	}
	return parseGuestResourceState(stdout)
}

func parseGuestResourceState(output string) (guestResourceState, error) {
	values := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = strings.TrimSpace(value)
		}
	}
	online, err := parseCPUList(values["cpu_online"])
	if err != nil {
		return guestResourceState{}, err
	}
	memTotalKiB, err := strconv.ParseInt(values["mem_total_kb"], 10, 64)
	if err != nil {
		return guestResourceState{}, fmt.Errorf("parse MemTotal %q: %w", values["mem_total_kb"], err)
	}
	cpuFields := strings.Fields(values["cpu_max"])
	if len(cpuFields) != 2 {
		return guestResourceState{}, fmt.Errorf("unexpected cpu.max %q", values["cpu_max"])
	}
	cpuQuota := int64(-1)
	if cpuFields[0] != "max" {
		cpuQuota, err = strconv.ParseInt(cpuFields[0], 10, 64)
		if err != nil {
			return guestResourceState{}, fmt.Errorf("parse cpu.max quota %q: %w", cpuFields[0], err)
		}
	}
	cpuPeriod, err := strconv.ParseInt(cpuFields[1], 10, 64)
	if err != nil {
		return guestResourceState{}, fmt.Errorf("parse cpu.max period %q: %w", cpuFields[1], err)
	}
	memoryMax := int64(-1)
	if values["memory_max"] != "max" {
		memoryMax, err = strconv.ParseInt(values["memory_max"], 10, 64)
		if err != nil {
			return guestResourceState{}, fmt.Errorf("parse memory.max %q: %w", values["memory_max"], err)
		}
	}
	return guestResourceState{
		OnlineCPUs:       online,
		MemoryTotalBytes: memTotalKiB * 1024,
		CPUQuota:         cpuQuota,
		CPUPeriod:        cpuPeriod,
		MemoryMaxBytes:   memoryMax,
	}, nil
}

func execGuestResourceStateFromNode(ctx context.Context, cfg *envconf.Config, pod *corev1.Pod, container string, command []string) (string, error) {
	frameworkClient, err := cfg.NewClient()
	if err != nil {
		return "", fmt.Errorf("create Kubernetes client: %w", err)
	}
	restCfg := rest.CopyConfig(frameworkClient.RESTConfig())
	// Resize polling is paced by this test. Avoid sharing the framework
	// client's token bucket with the main Pod status polling loop.
	restCfg.QPS, restCfg.RateLimiter = -1, nil
	client, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return "", fmt.Errorf("create Kubernetes clientset: %w", err)
	}
	podCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	currentPod, err := client.CoreV1().Pods(pod.Namespace).Get(podCtx, pod.Name, metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("get current Pod: %w", err)
	}
	status := containerStatusByName(currentPod, container)
	if status == nil || status.ContainerID == "" || currentPod.Spec.NodeName == "" {
		return "", fmt.Errorf("pod has no node/container identity")
	}
	containerID := strings.TrimPrefix(status.ContainerID, "containerd://")
	if containerID == status.ContainerID {
		return "", fmt.Errorf("unsupported container ID %q", status.ContainerID)
	}
	args := []string{
		"node-shell", currentPod.Spec.NodeName, "--",
		"crictl", "--runtime-endpoint", "unix:///run/containerd/containerd.sock",
		"exec", containerID,
	}
	args = append(args, command...)
	execCtx, cancelExec := context.WithTimeout(ctx, 15*time.Second)
	defer cancelExec()
	output, err := exec.CommandContext(execCtx, "kubectl", args...).CombinedOutput()
	if err != nil && completeGuestResourceStateOutput(string(output)) {
		// kubectl-node-shell can stream the result immediately, then remain
		// alive during pod cleanup until the deadline kills it. Keep the valid
		// observation instead of turning a test helper cleanup delay into a
		// resize failure.
		return string(output), nil
	}
	if err != nil {
		return "", fmt.Errorf("kubectl %s: %w: %s", strings.Join(args, " "), err, output)
	}
	return string(output), nil
}

func completeGuestResourceStateOutput(output string) bool {
	values := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		key, _, ok := strings.Cut(line, "=")
		if ok {
			values[strings.TrimSpace(key)] = true
		}
	}
	return values["cpu_online"] && values["mem_total_kb"] && values["cpu_max"] && values["memory_max"]
}

func readGuestResourceStateRequired(ctx context.Context, t *testing.T, cfg *envconf.Config, pod *corev1.Pod, container string) guestResourceState {
	t.Helper()
	state, err := readGuestResourceState(ctx, t, cfg, pod, container)
	if err != nil {
		t.Fatalf("inspect guest resources: %v", err)
	}
	return state
}

func parseCPUList(value string) (int, error) {
	if value == "" {
		return 0, fmt.Errorf("empty CPU list")
	}
	count := 0
	for _, part := range strings.Split(value, ",") {
		bounds := strings.SplitN(strings.TrimSpace(part), "-", 2)
		first, err := strconv.Atoi(bounds[0])
		if err != nil || first < 0 {
			return 0, fmt.Errorf("invalid CPU list %q", value)
		}
		last := first
		if len(bounds) == 2 {
			last, err = strconv.Atoi(bounds[1])
			if err != nil || last < first {
				return 0, fmt.Errorf("invalid CPU list %q", value)
			}
		}
		count += last - first + 1
	}
	return count, nil
}

func cubeNodeContainerdVersion(ctx context.Context, t *testing.T, client *kubernetes.Clientset) (*corev1.Node, containerdRuntimeVersion) {
	t.Helper()
	node, err := client.CoreV1().Nodes().Get(ctx, resolvedCubeNode(ctx, t, client), metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get cube node: %v", err)
	}
	version, err := parseContainerdRuntimeVersion(node.Status.NodeInfo.ContainerRuntimeVersion)
	if err != nil {
		t.Skipf("AGC-45 resize contract is defined for containerd nodes: %v", err)
	}
	return node, version
}

func requireContainerd24(ctx context.Context, t *testing.T, client *kubernetes.Clientset) *corev1.Node {
	t.Helper()
	node, version := cubeNodeContainerdVersion(ctx, t, client)
	if !version.supportsPodLevelResize() {
		t.Skipf("containerd %d.%d.%d only guarantees container-level resize; Pod-level SandboxService.UpdateSandbox requires containerd >= 2.4", version.Major, version.Minor, version.Patch)
	}
	t.Logf("AGC-45 Pod-level contract enabled: node=%s containerd=%s", node.Name, node.Status.NodeInfo.ContainerRuntimeVersion)
	return node
}

var containerdVersionPattern = regexp.MustCompile(`^containerd://v?(\d+)\.(\d+)(?:\.(\d+))?`)

func parseContainerdRuntimeVersion(value string) (containerdRuntimeVersion, error) {
	matches := containerdVersionPattern.FindStringSubmatch(value)
	if matches == nil {
		return containerdRuntimeVersion{}, fmt.Errorf("unsupported container runtime version %q", value)
	}
	parts := [3]int{}
	for i := range parts {
		if matches[i+1] == "" {
			continue
		}
		parsed, err := strconv.Atoi(matches[i+1])
		if err != nil {
			return containerdRuntimeVersion{}, fmt.Errorf("parse containerd version %q: %w", value, err)
		}
		parts[i] = parsed
	}
	return containerdRuntimeVersion{Major: parts[0], Minor: parts[1], Patch: parts[2]}, nil
}

func TestParseContainerdRuntimeVersion(t *testing.T) {
	tests := []struct {
		input string
		want  containerdRuntimeVersion
		ok    bool
	}{
		{input: "containerd://2.4.0", want: containerdRuntimeVersion{2, 4, 0}, ok: true},
		{input: "containerd://v2.4.1-rc.1", want: containerdRuntimeVersion{2, 4, 1}, ok: true},
		{input: "containerd://2.3", want: containerdRuntimeVersion{2, 3, 0}, ok: true},
		{input: "cri-o://1.35.0", ok: false},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			got, err := parseContainerdRuntimeVersion(test.input)
			if (err == nil) != test.ok {
				t.Fatalf("parseContainerdRuntimeVersion(%q) error=%v, ok=%t", test.input, err, test.ok)
			}
			if test.ok && got != test.want {
				t.Fatalf("parseContainerdRuntimeVersion(%q)=%+v, want %+v", test.input, got, test.want)
			}
		})
	}
}

func TestContainerdPodLevelResizeVersionGate(t *testing.T) {
	for _, test := range []struct {
		version containerdRuntimeVersion
		want    bool
	}{
		{version: containerdRuntimeVersion{1, 7, 27}, want: false},
		{version: containerdRuntimeVersion{2, 3, 4}, want: false},
		{version: containerdRuntimeVersion{2, 4, 0}, want: true},
		{version: containerdRuntimeVersion{3, 0, 0}, want: true},
	} {
		if got := test.version.supportsPodLevelResize(); got != test.want {
			t.Fatalf("containerd %+v supportsPodLevelResize=%t, want %t", test.version, got, test.want)
		}
	}
}

func TestParseCPUList(t *testing.T) {
	for input, want := range map[string]int{"0": 1, "0-3": 4, "0-1,4,6-7": 5} {
		got, err := parseCPUList(input)
		if err != nil || got != want {
			t.Fatalf("parseCPUList(%q)=(%d, %v), want (%d, nil)", input, got, err, want)
		}
	}
	for _, input := range []string{"", "3-1", "x"} {
		if _, err := parseCPUList(input); err == nil {
			t.Fatalf("parseCPUList(%q) unexpectedly succeeded", input)
		}
	}
}

func TestParseGuestResourceStateAllowsUnlimitedLeaf(t *testing.T) {
	state, err := parseGuestResourceState("cpu_online=0-1\nmem_total_kb=524288\ncpu_max=max 100000\nmemory_max=max\n")
	if err != nil {
		t.Fatalf("parse unlimited Pod-level child cgroup: %v", err)
	}
	if state.OnlineCPUs != 2 || state.MemoryTotalBytes != 512*bytesPerMiB || state.CPUQuota != -1 || state.CPUPeriod != 100000 || state.MemoryMaxBytes != -1 {
		t.Fatalf("unexpected unlimited Pod-level child state: %+v", state)
	}
}

func TestResourceRequirementsEqual(t *testing.T) {
	base := resizeResources("2", "1Gi")
	if !resourceRequirementsEqual(base, resizeResources("2000m", "1024Mi")) {
		t.Fatal("equivalent resource quantities must compare equal")
	}
	different := resizeResources("1", "1Gi")
	if resourceRequirementsEqual(base, different) {
		t.Fatal("different resource quantities must not compare equal")
	}
}

func TestPodLevelStatusResourcesIncludeRuntimeClassOverhead(t *testing.T) {
	resources := resizeResources("2", "1Gi")
	overhead := corev1.ResourceList{
		corev1.ResourceCPU:    resource.MustParse("250m"),
		corev1.ResourceMemory: resource.MustParse("768Mi"),
	}
	want := corev1.ResourceList{
		corev1.ResourceCPU:    resource.MustParse("2250m"),
		corev1.ResourceMemory: resource.MustParse("1792Mi"),
	}
	if got := addResourceLists(resources.Limits, overhead); !resourceListEqual(got, want) {
		t.Fatalf("resources plus RuntimeClass overhead=%v, want %v", got, want)
	}
}

func TestLeafCgroupAllowsPodLimit(t *testing.T) {
	if !leafCPUAllowsPodLimit(guestResourceState{CPUQuota: -1, CPUPeriod: 100000}, 2) ||
		!leafCPUAllowsPodLimit(guestResourceState{CPUQuota: 200000, CPUPeriod: 100000}, 2) ||
		leafCPUAllowsPodLimit(guestResourceState{CPUQuota: 100000, CPUPeriod: 100000}, 2) {
		t.Fatal("unexpected CPU leaf cgroup Pod-limit compatibility")
	}
	if !leafMemoryAllowsPodLimit(guestResourceState{MemoryMaxBytes: -1}, 1024) ||
		!leafMemoryAllowsPodLimit(guestResourceState{MemoryMaxBytes: 1024}, 1024) ||
		leafMemoryAllowsPodLimit(guestResourceState{MemoryMaxBytes: 512}, 1024) {
		t.Fatal("unexpected memory leaf cgroup Pod-limit compatibility")
	}
}

func TestGuestResourceStateUnchangedRejectsPartialResize(t *testing.T) {
	before := guestResourceState{
		OnlineCPUs:       1,
		MemoryTotalBytes: 512 * bytesPerMiB,
		CPUQuota:         100000,
		CPUPeriod:        100000,
		MemoryMaxBytes:   512 * bytesPerMiB,
	}
	if !guestResourceStateUnchanged(before, before) {
		t.Fatal("identical guest state must be unchanged")
	}
	partiallyApplied := before
	partiallyApplied.CPUQuota = 200000
	if guestResourceStateUnchanged(before, partiallyApplied) {
		t.Fatal("partial CPU resize must not satisfy an over-max rejection")
	}
	partiallyApplied = before
	partiallyApplied.MemoryMaxBytes = 1024 * bytesPerMiB
	if guestResourceStateUnchanged(before, partiallyApplied) {
		t.Fatal("partial memory resize must not satisfy an over-max rejection")
	}
}

func TestSetResizableResourcesPreservesExtendedResources(t *testing.T) {
	extended := corev1.ResourceName("tke.cloud.tencent.com/eni-ip")
	target := corev1.ResourceRequirements{
		Requests: corev1.ResourceList{extended: resource.MustParse("1")},
		Limits:   corev1.ResourceList{extended: resource.MustParse("1")},
	}
	setResizableResources(&target, resizeResources("2", "1Gi"))
	wantExtended := resource.MustParse("1")
	gotRequest := target.Requests[extended]
	gotLimit := target.Limits[extended]
	if gotRequest.Cmp(wantExtended) != 0 || gotLimit.Cmp(wantExtended) != 0 {
		t.Fatal("setResizableResources removed admission-injected extended resources")
	}
	if !resourceRequirementsEqual(target, resizeResources("2", "1Gi")) {
		t.Fatal("setResizableResources did not apply CPU and memory")
	}
}
