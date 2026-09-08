package e2eframework

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	nodev1 "k8s.io/api/node/v1"
	storagev1 "k8s.io/api/storage/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"sigs.k8s.io/e2e-framework/pkg/env"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
	"sigs.k8s.io/e2e-framework/pkg/features"
)

var testEnv env.Environment

var (
	runID        = flag.String("run-id", envString("RUN_ID", fmt.Sprintf("cube-kri-e2e-%s", time.Now().Format("20060102150405"))), "test run id used in pod labels")
	cubeNodeName = flag.String("cube-node", envString("CUBE_NODE_NAME", ""), "cube physical node name; auto-detected when empty")
	hostNodeName = flag.String("host-node", envString("HOST_NODE_NAME", ""), "physical host node name for host checks; defaults to cube node")
	runcNodeName = flag.String("runc-node", envString("RUNC_NODE_NAME", ""), "native runc node name for control test")
	probeOnly    = flag.Bool("probe-only", envBool("PROBE_ONLY", false), "run only probe semantic cases")
	keepPods     = flag.Bool("keep", envBool("KEEP", false), "keep test pods after the run")

	cubeImage    = flag.String("cube-image", envString("CUBE_IMAGE", "ccr.ccs.tencentyun.com/library/pause:latest"), "cube pause image")
	utilityImage = flag.String("utility-image", envString("UTILITY_IMAGE", "docker.io/library/alpine:latest"), "utility image")
	cubeAppID    = flag.String("cube-appid", envString("CUBE_APPID", "1253970226"), "cube appid label/annotation value")
	cubeNet      = flag.String("cube-master-net", envString("CUBE_MASTER_NET", `{"Mode":"WAN","BizGw":{"ID":1,"Tunnels":[]},"Version":1}`), "cube.master.net annotation value")

	containerCPU    = flag.String("container-cpu", envString("CONTAINER_CPU", "100m"), "container cpu request/limit")
	containerMemory = flag.String("container-memory", envString("CONTAINER_MEMORY", "128Mi"), "container memory request/limit")

	latencyConcurrency = flag.Int("latency-concurrency", envInt("LATENCY_CONCURRENCY", 100), "concurrent cube pause pods for latency test")
	latencyTimeout     = flag.Duration("latency-timeout", envDuration("LATENCY_TIMEOUT", 120*time.Second), "latency case timeout")
	semanticTimeout    = flag.Duration("semantic-timeout", envDuration("SEMANTIC_TIMEOUT", 60*time.Second), "semantic case startup timeout")
	probeTimeout       = flag.Duration("probe-timeout", envDuration("PROBE_TIMEOUT", 90*time.Second), "probe case timeout")
	cleanupTimeout     = flag.Duration("cleanup-timeout", envDuration("CLEANUP_TIMEOUT", 60*time.Second), "pod cleanup timeout")

	awvStorageClass = flag.String("awv-csi-storage-class", envString("AWV_CSI_STORAGE_CLASS", "awv-btrfs"), "awv-csi StorageClass used by PVC tests")
	awvCSIDriver    = flag.String("awv-csi-driver", envString("AWV_CSI_DRIVER", "agent-workspace.tke.cloud.tencent.com"), "expected awv-csi PV driver")
	awvPVCSize      = flag.String("awv-csi-pvc-size", envString("AWV_CSI_PVC_SIZE", "1Gi"), "awv-csi PVC request size")
)

const runLabelKey = "khaos.tencentcloud.com/test-run"

func TestMain(m *testing.M) {
	cfg, err := envconf.NewFromFlags()
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse e2e-framework flags: %v\n", err)
		os.Exit(2)
	}
	if cfg.Namespace() == "" {
		cfg.WithNamespace("default")
	}
	testEnv = env.NewWithConfig(cfg)
	os.Exit(testEnv.Run(m))
}

func TestProbeSemantics(t *testing.T) {
	feature := features.New("cube-kri probe semantics").
		WithLabel("scope", "probe").
		Assess("semantic-liveness-exec-restart", func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
			runProbeRestartCase(ctx, t, cfg, "semantic-liveness-exec-restart", probePodSpec{
				NameSuffix: "liveness-exec",
				Command:    []string{"/bin/sh", "-c", "touch /tmp/healthy; sleep 5; rm -f /tmp/healthy; sleep 3600"},
				Liveness: &corev1.Probe{
					ProbeHandler:        corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "test -f /tmp/healthy"}}},
					InitialDelaySeconds: 1,
					PeriodSeconds:       2,
					FailureThreshold:    1,
					TimeoutSeconds:      1,
				},
			})
			return ctx
		}).
		Assess("semantic-liveness-http-restart", func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
			runProbeRestartCase(ctx, t, cfg, "semantic-liveness-http-restart", probePodSpec{
				NameSuffix: "liveness-http",
				Command:    []string{"/bin/sh", "-c", "mkdir -p /www; echo ok > /www/healthz; httpd -f -p 8080 -h /www & sleep 5; rm -f /www/healthz; sleep 3600"},
				Ports:      []corev1.ContainerPort{{ContainerPort: 8080}},
				Liveness: &corev1.Probe{
					ProbeHandler:        corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromInt32(8080)}},
					InitialDelaySeconds: 1,
					PeriodSeconds:       2,
					FailureThreshold:    1,
					TimeoutSeconds:      1,
				},
			})
			return ctx
		}).
		Assess("semantic-liveness-tcp-restart", func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
			runProbeRestartCase(ctx, t, cfg, "semantic-liveness-tcp-restart", probePodSpec{
				NameSuffix: "liveness-tcp",
				Command:    []string{"/bin/sh", "-c", "mkdir -p /www; httpd -f -p 8081 -h /www & pid=$!; sleep 5; kill ${pid}; sleep 3600"},
				Ports:      []corev1.ContainerPort{{ContainerPort: 8081}},
				Liveness: &corev1.Probe{
					ProbeHandler:        corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(8081)}},
					InitialDelaySeconds: 1,
					PeriodSeconds:       2,
					FailureThreshold:    1,
					TimeoutSeconds:      1,
				},
			})
			return ctx
		}).
		Assess("semantic-readiness-exec-not-ready", func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
			runReadinessNegativeCase(ctx, t, cfg, probePodSpec{
				NameSuffix: "ready-exec",
				Command:    []string{"/bin/sh", "-c", "sleep 3600"},
				Readiness: &corev1.Probe{
					ProbeHandler:        corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "test -f /tmp/ready"}}},
					InitialDelaySeconds: 1,
					PeriodSeconds:       2,
					FailureThreshold:    1,
					TimeoutSeconds:      1,
				},
			})
			return ctx
		}).
		Feature()

	testEnv.Test(t, feature)
}

func TestLatency(t *testing.T) {
	if *probeOnly {
		t.Skip("probe-only=true")
	}

	feature := features.New("cube-kri latency").
		WithLabel("scope", "latency").
		Assess("latency-concurrent-cube-pods", assessConcurrentLatency).
		Feature()

	testEnv.Test(t, feature)
}

func TestCoreSemantics(t *testing.T) {
	if *probeOnly {
		t.Skip("probe-only=true")
	}

	feature := features.New("cube-kri core pod semantics").
		WithLabel("scope", "core").
		Assess("semantic-securitycontext-privileged", assessReadyPod("semantic-securitycontext-privileged", corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{baseContainer("main", []string{"/bin/sh", "-c", "sleep 3600"}, func(c *corev1.Container) {
				c.SecurityContext = &corev1.SecurityContext{Privileged: boolPtr(true)}
			})},
		})).
		Assess("semantic-initcontainer-emptydir", assessReadyPod("semantic-initcontainer-emptydir", corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Volumes:       []corev1.Volume{{Name: "work", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}},
			InitContainers: []corev1.Container{baseContainer("init-one", []string{"/bin/sh", "-c", "echo init > /work/init.done"}, func(c *corev1.Container) {
				c.VolumeMounts = []corev1.VolumeMount{{Name: "work", MountPath: "/work"}}
			})},
			Containers: []corev1.Container{baseContainer("main", []string{"/bin/sh", "-c", "test -f /work/init.done && sleep 3600"}, func(c *corev1.Container) {
				c.VolumeMounts = []corev1.VolumeMount{{Name: "work", MountPath: "/work"}}
			})},
		})).
		Assess("semantic-multicontainer", assessReadyPod("semantic-multicontainer", corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				baseContainer("one", []string{"/bin/sh", "-c", "sleep 3600"}),
				baseContainer("two", []string{"/bin/sh", "-c", "sleep 3600"}),
			},
		})).
		Assess("semantic-lifecycle-poststart-prestop-exec", assessLifecyclePod).
		Feature()

	testEnv.Test(t, feature)
}

func TestRuntimeMix(t *testing.T) {
	if *probeOnly {
		t.Skip("probe-only=true")
	}

	feature := features.New("cube-kri runtime mix").
		WithLabel("scope", "runtime").
		Assess("runtime-mix-khaoslet-default-runc", assessRuncPodOnCubeNode("runtime-mix-default-runc", "")).
		Assess("runtime-mix-khaoslet-runtimeclass-runc", assessRuncPodOnCubeNode("runtime-mix-rc-runc", "runc")).
		Assess("runtime-mix-khaoslet-runc-hostpath", assessRuncHostPathPod).
		Assess("runtime-mix-khaoslet-runc-daemonset", assessRuncDaemonSet).
		Assess("runtime-mix-native-runc-node-control", assessNativeRuncPod).
		Feature()

	testEnv.Test(t, feature)
}

func TestAWVCSIPVC(t *testing.T) {
	if *probeOnly {
		t.Skip("probe-only=true")
	}

	feature := features.New("cube-kri awv-csi pvc").
		WithLabel("scope", "storage").
		Assess("awv-csi-pvc-cube-pod-read-write", assessAWVCSIPVCCubePod).
		Feature()

	testEnv.Test(t, feature)
}

type probePodSpec struct {
	NameSuffix string
	Command    []string
	Ports      []corev1.ContainerPort
	Liveness   *corev1.Probe
	Readiness  *corev1.Probe
}

func runProbeRestartCase(ctx context.Context, t *testing.T, cfg *envconf.Config, caseName string, spec probePodSpec) {
	client := clientset(t, cfg)
	pod := probePod(t, ctx, cfg, client, spec, corev1.RestartPolicyAlways)
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	waitPodPhase(ctx, t, client, pod.Namespace, pod.Name, corev1.PodRunning, *semanticTimeout)
	var got *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, *probeTimeout, true, func(ctx context.Context) (bool, error) {
		p, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		got = p
		return podPhase(p) == corev1.PodRunning && firstRestartCount(p) > 0, nil
	})
	if err != nil {
		t.Fatalf("%s: expected liveness restart within %s; %s; events=%s", caseName, *probeTimeout, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	t.Logf("%s: %s", caseName, podSummary(got))
}

func runReadinessNegativeCase(ctx context.Context, t *testing.T, cfg *envconf.Config, spec probePodSpec) {
	client := clientset(t, cfg)
	pod := probePod(t, ctx, cfg, client, spec, corev1.RestartPolicyAlways)
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	waitPodPhase(ctx, t, client, pod.Namespace, pod.Name, corev1.PodRunning, *semanticTimeout)
	var got *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, 15*time.Second, true, func(ctx context.Context) (bool, error) {
		p, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		got = p
		return podReady(p) == corev1.ConditionFalse && firstRestartCount(p) == 0, nil
	})
	if err != nil {
		t.Fatalf("semantic-readiness-exec-not-ready: expected Running/Ready=False/restartCount=0; %s; events=%s", podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	t.Logf("semantic-readiness-exec-not-ready: %s", podSummary(got))
}

func assessReadyPod(name string, spec corev1.PodSpec) features.Func {
	return func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
		client := clientset(t, cfg)
		pod := cubePod(t, ctx, cfg, client, name, spec)
		createPod(ctx, t, client, pod)
		defer cleanupPod(ctx, t, client, pod)
		got := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
		t.Logf("%s: %s", name, podSummary(got))
		return ctx
	}
}

func assessLifecyclePod(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	pod := cubePod(t, ctx, cfg, client, "semantic-lifecycle", corev1.PodSpec{
		RestartPolicy:                 corev1.RestartPolicyNever,
		TerminationGracePeriodSeconds: int64Ptr(10),
		Volumes:                       []corev1.Volume{{Name: "hooks", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}},
		Containers: []corev1.Container{baseContainer("main", []string{"/bin/sh", "-c", "echo main-start > /hooks/main-start; sleep 3600"}, func(c *corev1.Container) {
			c.VolumeMounts = []corev1.VolumeMount{{Name: "hooks", MountPath: "/hooks"}}
			c.Lifecycle = &corev1.Lifecycle{
				PostStart: &corev1.LifecycleHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "echo poststart > /hooks/poststart"}}},
				PreStop:   &corev1.LifecycleHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "sleep 3"}}},
			}
		})},
	})
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)

	got := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	t.Logf("semantic-lifecycle ready: %s", podSummary(got))

	cmd := []string{"/bin/sh", "-c", "test -f /hooks/main-start && test -f /hooks/poststart"}
	if _, _, err := execInPod(ctx, cfg, pod.Namespace, pod.Name, "main", cmd); err != nil {
		t.Fatalf("postStart files not observed: %v", err)
	}

	start := time.Now()
	if err := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Fatalf("delete lifecycle pod: %v", err)
	}
	waitForPodDeleted(ctx, t, client, pod.Namespace, pod.Name, 30*time.Second)
	if elapsed := time.Since(start); elapsed < 2500*time.Millisecond {
		t.Fatalf("preStop did not delay deletion enough: elapsed=%s", elapsed)
	}
	return ctx
}

func assessNativeRuncPod(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	node := resolvedRuncNode(ctx, t, client)
	if *hostNodeName == "" {
		*hostNodeName = resolvedCubeNode(ctx, t, client)
	}
	pod := podBase(t, cfg, "runtime-mix-native-runc")
	pod.Spec = corev1.PodSpec{
		NodeName:      node,
		HostNetwork:   true,
		RestartPolicy: corev1.RestartPolicyNever,
		Containers:    []corev1.Container{baseContainer("main", []string{"/bin/sh", "-c", "sleep 3600"})},
	}
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)
	got := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	t.Logf("runtime-mix-native-runc-node-control: %s", podSummary(got))
	return ctx
}

func assessRuncPodOnCubeNode(suffix, runtimeClass string) features.Func {
	return func(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
		client := clientset(t, cfg)
		ensureRuntimeClasses(ctx, t, client)
		pod := runcPodOnCubeNode(ctx, t, cfg, client, suffix, runtimeClass, noResourceContainer("main", []string{"/bin/sh", "-c", "sleep 3600"}))
		createPod(ctx, t, client, pod)
		defer cleanupPod(ctx, t, client, pod)
		got := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
		t.Logf("%s: %s", suffix, podSummary(got))
		return ctx
	}
}

func assessRuncHostPathPod(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	ensureRuntimeClasses(ctx, t, client)
	hostPath := filepath.Join("/data/cubelet/hostpath", dnsName(*runID+"-runc-hostpath"))
	defer cleanupHostPath(ctx, t, cfg, client, hostPath)

	container := baseContainer("main", []string{"/bin/sh", "-c", `echo from-pod > /host/pod.txt; test "$(cat /host/pod.txt)" = from-pod; sleep 3600`}, func(c *corev1.Container) {
		c.VolumeMounts = []corev1.VolumeMount{{Name: "host-data", MountPath: "/host"}}
	})
	hostPathType := corev1.HostPathDirectoryOrCreate
	pod := runcPodOnCubeNode(ctx, t, cfg, client, "runtime-mix-runc-hostpath", "runc", container)
	pod.Spec.Volumes = []corev1.Volume{{
		Name: "host-data",
		VolumeSource: corev1.VolumeSource{
			HostPath: &corev1.HostPathVolumeSource{Path: hostPath, Type: &hostPathType},
		},
	}}
	createPod(ctx, t, client, pod)
	defer cleanupPod(ctx, t, client, pod)
	got := waitPodReady(ctx, t, client, pod.Namespace, pod.Name, *semanticTimeout)
	if _, _, err := execInPod(ctx, cfg, pod.Namespace, pod.Name, "main", []string{"/bin/sh", "-c", `test "$(cat /host/pod.txt)" = from-pod`}); err != nil {
		t.Fatalf("hostPath content not observed: %v; %s; events=%s", err, podSummary(got), podEvents(ctx, client, pod.Namespace, pod.Name))
	}
	t.Logf("runtime-mix-khaoslet-runc-hostpath: %s", podSummary(got))
	return ctx
}

func assessRuncDaemonSet(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	ensureRuntimeClasses(ctx, t, client)
	ns := namespace(cfg)
	name := dnsName(*runID + "-runc-ds")
	caseLabels := map[string]string{
		runLabelKey:                        *runID,
		"khaos.tencentcloud.com/test-case": "runc-daemonset",
	}
	ds := &appsv1.DaemonSet{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: map[string]string{runLabelKey: *runID}},
		Spec: appsv1.DaemonSetSpec{
			Selector: &metav1.LabelSelector{MatchLabels: caseLabels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: caseLabels},
				Spec: corev1.PodSpec{
					NodeSelector:       map[string]string{"kubernetes.io/hostname": resolvedCubeNode(ctx, t, client)},
					RuntimeClassName:   stringPtr("runc"),
					HostNetwork:        true,
					RestartPolicy:      corev1.RestartPolicyAlways,
					Tolerations:        []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
					Containers:         []corev1.Container{baseContainer("main", []string{"/bin/sh", "-c", "sleep 3600"})},
					ServiceAccountName: "",
				},
			},
		},
	}
	if err := client.AppsV1().DaemonSets(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Fatalf("delete stale daemonset %s/%s: %v", ns, name, err)
	}
	waitForDaemonSetDeleted(ctx, t, client, ns, name, *cleanupTimeout)
	if _, err := client.AppsV1().DaemonSets(ns).Create(ctx, ds, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create daemonset %s/%s: %v", ns, name, err)
	}
	defer cleanupDaemonSet(ctx, t, client, ns, name)

	pod := waitDaemonSetPodReady(ctx, t, client, ns, labels.SelectorFromSet(caseLabels).String(), *semanticTimeout)
	t.Logf("runtime-mix-khaoslet-runc-daemonset: %s", podSummary(pod))
	return ctx
}

func assessAWVCSIPVCCubePod(ctx context.Context, t *testing.T, cfg *envconf.Config) context.Context {
	client := clientset(t, cfg)
	ensureRuntimeClasses(ctx, t, client)
	ensureStorageClass(ctx, t, client, *awvStorageClass)

	ns := namespace(cfg)
	pvcName := dnsName(*runID + "-awv-pvc")
	cleanupPVC(ctx, t, client, ns, pvcName)
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      pvcName,
			Namespace: ns,
			Labels: map[string]string{
				runLabelKey:                        *runID,
				"khaos.tencentcloud.com/test-case": "awv-csi-pvc",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
			StorageClassName: stringPtr(*awvStorageClass),
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceStorage: resource.MustParse(*awvPVCSize),
				},
			},
		},
	}
	if _, err := client.CoreV1().PersistentVolumeClaims(ns).Create(ctx, pvc, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create awv-csi pvc %s/%s: %v", ns, pvcName, err)
	}
	defer cleanupPVC(ctx, t, client, ns, pvcName)

	marker := fmt.Sprintf("%s/marker.txt", *runID)
	writer := awvCSIPVCPod(t, ctx, cfg, client, "awv-csi-pvc-write", pvcName, `set -eu; mkdir -p /workspace/"${RUN_ID}"; echo ok > /workspace/"${RUN_ID}"/marker.txt; sleep 3600`)
	createPod(ctx, t, client, writer)
	defer cleanupPod(ctx, t, client, writer)
	got := waitPodReady(ctx, t, client, writer.Namespace, writer.Name, 4*time.Minute)
	boundPVC := waitPVCBound(ctx, t, client, ns, pvcName, time.Minute)
	pv := assertAWVCSIPV(ctx, t, client, boundPVC.Spec.VolumeName)
	waitPodExecStdout(ctx, t, cfg, client, writer.Namespace, writer.Name, "main", []string{"/bin/sh", "-c", `set -eu; cat /workspace/"${RUN_ID}"/marker.txt`}, "ok", 90*time.Second)
	cleanupPod(ctx, t, client, writer)

	reused := waitCubeCSIPVCReaderContent(ctx, t, cfg, client, pvcName, 3*time.Minute)
	defer cleanupPod(ctx, t, client, reused)
	cleanupPod(ctx, t, client, reused)

	nativeRead := waitNativeCSIPVCReaderContent(ctx, t, cfg, client, pvcName, 3*time.Minute)
	defer cleanupPod(ctx, t, client, nativeRead)
	t.Logf("awv-csi-pvc-cross-runtime-read: cubeWriter=%s cubeReader=%s nativeReader=%s pvc=%s pv=%s driver=%s marker=%s", podSummary(got), podSummary(reused), podSummary(nativeRead), pvcName, pv.Name, pv.Spec.CSI.Driver, marker)
	return ctx
}

func waitCubeCSIPVCReaderContent(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, pvcName string, timeout time.Duration) *corev1.Pod {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last string
	for attempt := 1; time.Now().Before(deadline); attempt++ {
		reader := awvCSIPVCPod(t, ctx, cfg, client, fmt.Sprintf("awv-csi-pvc-read-%d", attempt), pvcName, `set -eu; sleep 3600`)
		createPod(ctx, t, client, reader)
		ready, err := waitPodReadyResult(ctx, client, reader.Namespace, reader.Name, minDuration(45*time.Second, time.Until(deadline)))
		if err == nil {
			stdout, stderr, err := execInPod(ctx, cfg, reader.Namespace, reader.Name, "main", []string{"/bin/sh", "-c", `set -eu; cat /workspace/"${RUN_ID}"/marker.txt`})
			if err == nil && strings.TrimSpace(stdout) == "ok" {
				return ready
			}
			last = fmt.Sprintf("attempt=%d err=%v stdout=%q stderr=%q pod=%s events=%s", attempt, err, stdout, stderr, podSummary(ready), podEvents(ctx, client, reader.Namespace, reader.Name))
		} else {
			last = fmt.Sprintf("attempt=%d readyErr=%v pod=%s events=%s", attempt, err, podSummary(ready), podEvents(ctx, client, reader.Namespace, reader.Name))
		}
		cleanupPod(ctx, t, client, reader)
		select {
		case <-ctx.Done():
			t.Fatalf("awv-csi pvc cube reader check canceled: %v; last=%s", ctx.Err(), last)
		case <-time.After(10 * time.Second):
		}
	}
	t.Fatalf("awv-csi pvc cube reader did not observe writer content within %s; last=%s", timeout, last)
	return nil
}

func waitNativeCSIPVCReaderContent(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, pvcName string, timeout time.Duration) *corev1.Pod {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last string
	for attempt := 1; time.Now().Before(deadline); attempt++ {
		nativeReader := nativeCSIPVCReaderPod(t, ctx, cfg, client, fmt.Sprintf("awv-csi-pvc-native-read-%d", attempt), pvcName)
		createPod(ctx, t, client, nativeReader)
		nativeRead := waitPodReady(ctx, t, client, nativeReader.Namespace, nativeReader.Name, 4*time.Minute)
		stdout, stderr, err := execInPod(ctx, cfg, nativeReader.Namespace, nativeReader.Name, "main", []string{"/bin/sh", "-c", `set -eu; cat /workspace/"${RUN_ID}"/marker.txt`})
		if err == nil && strings.TrimSpace(stdout) == "ok" {
			return nativeRead
		}
		last = fmt.Sprintf("attempt=%d err=%v stdout=%q stderr=%q pod=%s events=%s", attempt, err, stdout, stderr, podSummary(nativeRead), podEvents(ctx, client, nativeReader.Namespace, nativeReader.Name))
		cleanupPod(ctx, t, client, nativeReader)
		select {
		case <-ctx.Done():
			t.Fatalf("awv-csi pvc native node check canceled: %v; last=%s", ctx.Err(), last)
		case <-time.After(10 * time.Second):
		}
	}
	t.Fatalf("awv-csi pvc native node check did not observe writer content within %s; last=%s", timeout, last)
	return nil
}

func waitPodExecStdout(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, ns, pod, container string, command []string, want string, timeout time.Duration) {
	t.Helper()
	var last string
	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		stdout, stderr, err := execInPod(ctx, cfg, ns, pod, container, command)
		if err == nil && strings.TrimSpace(stdout) == want {
			return true, nil
		}
		last = fmt.Sprintf("err=%v stdout=%q stderr=%q", err, stdout, stderr)
		return false, nil
	})
	if err == nil {
		return
	}
	got, getErr := client.CoreV1().Pods(ns).Get(ctx, pod, metav1.GetOptions{})
	if getErr != nil {
		last = fmt.Sprintf("%s getPodErr=%v", last, getErr)
	}
	t.Fatalf("pod %s/%s exec output did not become %q within %s; last=%s; %s; events=%s", ns, pod, want, timeout, last, podSummary(got), podEvents(ctx, client, ns, pod))
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func awvCSIPVCPod(t *testing.T, ctx context.Context, cfg *envconf.Config, client *kubernetes.Clientset, suffix, pvcName, command string) *corev1.Pod {
	t.Helper()
	container := baseContainer("main", []string{"/bin/sh", "-c", command}, func(c *corev1.Container) {
		c.Env = []corev1.EnvVar{{Name: "RUN_ID", Value: *runID}}
		c.VolumeMounts = []corev1.VolumeMount{{Name: "workspace", MountPath: "/workspace"}}
	})
	pod := podBase(t, cfg, suffix)
	pod.Spec = corev1.PodSpec{
		RuntimeClassName:              stringPtr("cube"),
		NodeSelector:                  map[string]string{"kubernetes.io/hostname": resolvedCubeNode(ctx, t, client)},
		Tolerations:                   []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
		RestartPolicy:                 corev1.RestartPolicyNever,
		AutomountServiceAccountToken:  boolPtr(false),
		TerminationGracePeriodSeconds: int64Ptr(5),
		Volumes: []corev1.Volume{{
			Name: "workspace",
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: pvcName},
			},
		}},
		Containers: []corev1.Container{container},
	}
	return pod
}

func nativeCSIPVCReaderPod(t *testing.T, ctx context.Context, cfg *envconf.Config, client *kubernetes.Clientset, suffix, pvcName string) *corev1.Pod {
	t.Helper()
	container := baseContainer("main", []string{"/bin/sh", "-c", `set -eu; sleep 3600`}, func(c *corev1.Container) {
		c.Env = []corev1.EnvVar{{Name: "RUN_ID", Value: *runID}}
		c.VolumeMounts = []corev1.VolumeMount{{Name: "workspace", MountPath: "/workspace"}}
	})
	pod := podBase(t, cfg, suffix)
	pod.Spec = corev1.PodSpec{
		NodeName:                      resolvedRuncNode(ctx, t, client),
		RestartPolicy:                 corev1.RestartPolicyNever,
		Tolerations:                   []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
		AutomountServiceAccountToken:  boolPtr(false),
		TerminationGracePeriodSeconds: int64Ptr(5),
		Volumes: []corev1.Volume{{
			Name: "workspace",
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: pvcName},
			},
		}},
		Containers: []corev1.Container{container},
	}
	return pod
}

func probePod(t *testing.T, ctx context.Context, cfg *envconf.Config, client *kubernetes.Clientset, spec probePodSpec, restartPolicy corev1.RestartPolicy) *corev1.Pod {
	container := baseContainer("main", spec.Command, func(c *corev1.Container) {
		c.Ports = spec.Ports
		c.LivenessProbe = spec.Liveness
		c.ReadinessProbe = spec.Readiness
	})
	return cubePod(t, ctx, cfg, client, spec.NameSuffix, corev1.PodSpec{
		RestartPolicy: restartPolicy,
		Containers:    []corev1.Container{container},
	})
}

func cubePod(t *testing.T, ctx context.Context, cfg *envconf.Config, client *kubernetes.Clientset, suffix string, spec corev1.PodSpec) *corev1.Pod {
	ensureRuntimeClasses(ctx, t, client)
	pod := podBase(t, cfg, suffix)
	spec.NodeName = resolvedCubeNode(ctx, t, client)
	spec.RuntimeClassName = stringPtr("cube")
	pod.Spec = spec
	return pod
}

func runcPodOnCubeNode(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, suffix, runtimeClass string, container corev1.Container) *corev1.Pod {
	pod := podBase(t, cfg, suffix)
	pod.Spec = corev1.PodSpec{
		NodeName:      resolvedCubeNode(ctx, t, client),
		HostNetwork:   true,
		RestartPolicy: corev1.RestartPolicyNever,
		Tolerations:   []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
		Containers:    []corev1.Container{container},
	}
	if runtimeClass != "" {
		pod.Spec.RuntimeClassName = stringPtr(runtimeClass)
	}
	return pod
}

func podBase(t *testing.T, cfg *envconf.Config, suffix string) *corev1.Pod {
	t.Helper()
	ns := cfg.Namespace()
	if ns == "" {
		ns = "default"
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      dnsName(*runID + "-" + suffix),
			Namespace: ns,
			Labels: map[string]string{
				runLabelKey: *runID,
			},
		},
	}
}

func baseContainer(name string, command []string, opts ...func(*corev1.Container)) corev1.Container {
	c := corev1.Container{
		Name:            name,
		Image:           *utilityImage,
		ImagePullPolicy: corev1.PullIfNotPresent,
		Command:         command,
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(*containerCPU),
				corev1.ResourceMemory: resource.MustParse(*containerMemory),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(*containerCPU),
				corev1.ResourceMemory: resource.MustParse(*containerMemory),
			},
		},
	}
	for _, opt := range opts {
		opt(&c)
	}
	return c
}

func noResourceContainer(name string, command []string, opts ...func(*corev1.Container)) corev1.Container {
	c := corev1.Container{
		Name:            name,
		Image:           *utilityImage,
		ImagePullPolicy: corev1.PullIfNotPresent,
		Command:         command,
	}
	for _, opt := range opts {
		opt(&c)
	}
	return c
}

func pauseContainer(name string) corev1.Container {
	c := baseContainer(name, nil)
	c.Image = *cubeImage
	return c
}

func ensureRuntimeClasses(ctx context.Context, t *testing.T, client *kubernetes.Clientset) {
	t.Helper()
	for name, handler := range map[string]string{"cube": "cube", "runc": "runc"} {
		got, err := client.NodeV1().RuntimeClasses().Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			if got.Handler != handler {
				t.Fatalf("runtimeclass %s handler=%q, want %q", name, got.Handler, handler)
			}
			continue
		}
		if !apierrors.IsNotFound(err) {
			t.Fatalf("get runtimeclass %s: %v", name, err)
		}
		_, err = client.NodeV1().RuntimeClasses().Create(ctx, &nodev1.RuntimeClass{
			ObjectMeta: metav1.ObjectMeta{Name: name},
			Handler:    handler,
		}, metav1.CreateOptions{})
		if err != nil && !apierrors.IsAlreadyExists(err) {
			t.Fatalf("create runtimeclass %s: %v", name, err)
		}
	}
}

func createPod(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod) {
	t.Helper()
	if err := createPodErr(ctx, client, pod); err != nil {
		t.Fatal(err)
	}
}

func createPodErr(ctx context.Context, client *kubernetes.Clientset, pod *corev1.Pod) error {
	if err := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("delete stale pod %s/%s: %w", pod.Namespace, pod.Name, err)
	}
	_ = wait.PollUntilContextTimeout(ctx, time.Second, 15*time.Second, true, func(ctx context.Context) (bool, error) {
		_, err := client.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		return apierrors.IsNotFound(err), nil
	})
	if _, err := client.CoreV1().Pods(pod.Namespace).Create(ctx, pod, metav1.CreateOptions{}); err != nil {
		return fmt.Errorf("create pod %s/%s: %w", pod.Namespace, pod.Name, err)
	}
	return nil
}

func cleanupPods(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pods []*corev1.Pod) {
	t.Helper()
	for _, pod := range pods {
		cleanupPod(ctx, t, client, pod)
	}
}

func cleanupPod(ctx context.Context, t *testing.T, client *kubernetes.Clientset, pod *corev1.Pod) {
	t.Helper()
	if *keepPods {
		return
	}
	if err := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Logf("delete pod %s/%s: %v", pod.Namespace, pod.Name, err)
	}
	if waitForPodDeleted(ctx, t, client, pod.Namespace, pod.Name, *cleanupTimeout) {
		return
	}
	grace := int64(0)
	if err := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{GracePeriodSeconds: &grace}); err != nil && !apierrors.IsNotFound(err) {
		t.Logf("force delete pod %s/%s: %v", pod.Namespace, pod.Name, err)
	}
	waitForPodDeleted(ctx, t, client, pod.Namespace, pod.Name, 10*time.Second)
}

func cleanupDaemonSet(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string) {
	t.Helper()
	if *keepPods {
		return
	}
	if err := client.AppsV1().DaemonSets(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Logf("delete daemonset %s/%s: %v", ns, name, err)
	}
	waitForDaemonSetDeleted(ctx, t, client, ns, name, *cleanupTimeout)
}

func cleanupPVC(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string) {
	t.Helper()
	if *keepPods {
		return
	}
	if err := client.CoreV1().PersistentVolumeClaims(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Logf("delete pvc %s/%s: %v", ns, name, err)
	}
	waitForPVCDeleted(ctx, t, client, ns, name, *cleanupTimeout)
}

func cleanupHostPath(ctx context.Context, t *testing.T, cfg *envconf.Config, client *kubernetes.Clientset, hostPath string) {
	t.Helper()
	if *keepPods {
		return
	}
	if *hostNodeName == "" {
		*hostNodeName = resolvedCubeNode(ctx, t, client)
	}
	pod := podBase(t, cfg, "cleanup-hostpath")
	pod.Spec = corev1.PodSpec{
		NodeName:      *hostNodeName,
		HostNetwork:   true,
		RestartPolicy: corev1.RestartPolicyNever,
		Tolerations:   []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
		Volumes: []corev1.Volume{{
			Name: "host-root",
			VolumeSource: corev1.VolumeSource{
				HostPath: &corev1.HostPathVolumeSource{Path: "/", Type: hostPathTypePtr(corev1.HostPathDirectory)},
			},
		}},
		Containers: []corev1.Container{noResourceContainer("main", []string{"/bin/sh", "-c", `rm -rf -- "${TARGET}"`}, func(c *corev1.Container) {
			c.Env = []corev1.EnvVar{{Name: "TARGET", Value: "/host" + hostPath}}
			c.SecurityContext = &corev1.SecurityContext{Privileged: boolPtr(true)}
			c.VolumeMounts = []corev1.VolumeMount{{Name: "host-root", MountPath: "/host"}}
		})},
	}
	if err := createPodErr(ctx, client, pod); err != nil {
		t.Logf("create hostPath cleanup pod: %v", err)
		return
	}
	defer cleanupPod(ctx, t, client, pod)
	waitPodPhase(ctx, t, client, pod.Namespace, pod.Name, corev1.PodSucceeded, 30*time.Second)
}

func ensureStorageClass(ctx context.Context, t *testing.T, client *kubernetes.Clientset, name string) *storagev1.StorageClass {
	t.Helper()
	sc, err := client.StorageV1().StorageClasses().Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		t.Skipf("StorageClass %q not found", name)
	}
	if err != nil {
		t.Fatalf("get storageclass %q: %v", name, err)
	}
	return sc
}

func notReadySummary(pods []*corev1.Pod) string {
	parts := make([]string, 0, len(pods))
	for _, pod := range pods {
		if podPhase(pod) == corev1.PodRunning && allContainersReady(pod) {
			continue
		}
		parts = append(parts, pod.Name+"="+podSummary(pod))
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, " | ")
}

func waitPodReady(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, timeout time.Duration) *corev1.Pod {
	t.Helper()
	got, err := waitPodReadyResult(ctx, client, ns, name, timeout)
	if err != nil {
		t.Fatalf("pod %s/%s did not become ready within %s: %s; events=%s", ns, name, timeout, podSummary(got), podEvents(ctx, client, ns, name))
	}
	return got
}

func waitPodReadyResult(ctx context.Context, client *kubernetes.Clientset, ns, name string, timeout time.Duration) (*corev1.Pod, error) {
	var got *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		p, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			return false, err
		}
		got = p
		return podPhase(p) == corev1.PodRunning && allContainersReady(p), nil
	})
	if err != nil {
		return got, err
	}
	return got, nil
}

func waitPodPhase(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, phase corev1.PodPhase, timeout time.Duration) *corev1.Pod {
	t.Helper()
	var got *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		p, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			return false, err
		}
		got = p
		return podPhase(p) == phase, nil
	})
	if err != nil {
		t.Fatalf("pod %s/%s did not reach phase %s within %s: %s; events=%s", ns, name, phase, timeout, podSummary(got), podEvents(ctx, client, ns, name))
	}
	return got
}

func waitForPodDeleted(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, timeout time.Duration) bool {
	t.Helper()
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		_, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Logf("pod %s/%s was not deleted within %s", ns, name, timeout)
		return false
	}
	return true
}

func waitForPVCDeleted(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, timeout time.Duration) bool {
	t.Helper()
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		_, err := client.CoreV1().PersistentVolumeClaims(ns).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Logf("pvc %s/%s was not deleted within %s", ns, name, timeout)
		return false
	}
	return true
}

func waitForDaemonSetDeleted(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, timeout time.Duration) bool {
	t.Helper()
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		_, err := client.AppsV1().DaemonSets(ns).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Logf("daemonset %s/%s was not deleted within %s", ns, name, timeout)
		return false
	}
	return true
}

func waitDaemonSetPodReady(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, selector string, timeout time.Duration) *corev1.Pod {
	t.Helper()
	var got *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		pods, err := client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: selector})
		if err != nil {
			return false, err
		}
		for i := range pods.Items {
			pod := &pods.Items[i]
			got = pod
			if podPhase(pod) == corev1.PodRunning && allContainersReady(pod) {
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		name := ""
		if got != nil {
			name = got.Name
		}
		t.Fatalf("daemonset pod did not become ready within %s: %s; events=%s", timeout, podSummary(got), podEvents(ctx, client, ns, name))
	}
	return got
}

func waitPVCBound(ctx context.Context, t *testing.T, client *kubernetes.Clientset, ns, name string, timeout time.Duration) *corev1.PersistentVolumeClaim {
	t.Helper()
	var got *corev1.PersistentVolumeClaim
	err := wait.PollUntilContextTimeout(ctx, time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		pvc, err := client.CoreV1().PersistentVolumeClaims(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			return false, err
		}
		got = pvc
		return pvc.Status.Phase == corev1.ClaimBound && pvc.Spec.VolumeName != "", nil
	})
	if err != nil {
		t.Fatalf("pvc %s/%s did not become Bound within %s: phase=%s volume=%q", ns, name, timeout, gotPVCPhase(got), gotPVCVolume(got))
	}
	return got
}

func assertAWVCSIPV(ctx context.Context, t *testing.T, client *kubernetes.Clientset, name string) *corev1.PersistentVolume {
	t.Helper()
	pv, err := client.CoreV1().PersistentVolumes().Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get pv %q: %v", name, err)
	}
	if pv.Spec.CSI == nil {
		t.Fatalf("pv %q is not a CSI PV", name)
	}
	if pv.Spec.CSI.Driver != *awvCSIDriver {
		t.Fatalf("pv %q CSI driver=%q, want %q", name, pv.Spec.CSI.Driver, *awvCSIDriver)
	}
	if pv.Spec.VolumeMode != nil && *pv.Spec.VolumeMode == corev1.PersistentVolumeBlock {
		t.Fatalf("pv %q is Block mode, want Filesystem", name)
	}
	return pv
}

func resolvedCubeNode(ctx context.Context, t *testing.T, client *kubernetes.Clientset) string {
	t.Helper()
	if *cubeNodeName != "" {
		return *cubeNodeName
	}
	nodes, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{LabelSelector: "cubesandbox.io/runtime=cube"})
	if err != nil {
		t.Fatalf("list cube physical nodes: %v", err)
	}
	for _, node := range nodes.Items {
		if node.Spec.Unschedulable || !strings.Contains(node.Status.NodeInfo.OSImage, "TencentOS Server 4") {
			continue
		}
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
				*cubeNodeName = node.Name
				return node.Name
			}
		}
	}
	t.Fatalf("cannot detect Ready cube physical node; set -cube-node")
	return ""
}

func resolvedRuncNode(ctx context.Context, t *testing.T, client *kubernetes.Clientset) string {
	t.Helper()
	cubeNode := resolvedCubeNode(ctx, t, client)
	if *runcNodeName != "" {
		if *runcNodeName == cubeNode {
			t.Skip("runc node equals cube node")
		}
		return *runcNodeName
	}
	nodes, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{LabelSelector: "node.kubernetes.io/instance-type!=khaoslet"})
	if err != nil {
		t.Fatalf("list physical nodes: %v", err)
	}
	for _, node := range nodes.Items {
		if node.Name == cubeNode {
			continue
		}
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
				*runcNodeName = node.Name
				return node.Name
			}
		}
	}
	t.Skip("no secondary Ready physical node for native runc control")
	return ""
}

func clientset(t *testing.T, cfg *envconf.Config) *kubernetes.Clientset {
	t.Helper()
	client, err := cfg.NewClient()
	if err != nil {
		t.Fatalf("new e2e-framework client: %v", err)
	}
	cs, err := kubernetes.NewForConfig(client.RESTConfig())
	if err != nil {
		t.Fatalf("new kubernetes clientset: %v", err)
	}
	return cs
}

func namespace(cfg *envconf.Config) string {
	ns := cfg.Namespace()
	if ns == "" {
		return "default"
	}
	return ns
}

func podPhase(pod *corev1.Pod) corev1.PodPhase {
	if pod == nil {
		return ""
	}
	return pod.Status.Phase
}

func allContainersReady(pod *corev1.Pod) bool {
	if pod == nil || len(pod.Status.ContainerStatuses) == 0 {
		return false
	}
	for _, status := range pod.Status.ContainerStatuses {
		if !status.Ready {
			return false
		}
	}
	return true
}

func podReady(pod *corev1.Pod) corev1.ConditionStatus {
	if pod == nil {
		return corev1.ConditionUnknown
	}
	for _, cond := range pod.Status.Conditions {
		if cond.Type == corev1.PodReady {
			return cond.Status
		}
	}
	return corev1.ConditionUnknown
}

func gotPVCPhase(pvc *corev1.PersistentVolumeClaim) corev1.PersistentVolumeClaimPhase {
	if pvc == nil {
		return ""
	}
	return pvc.Status.Phase
}

func gotPVCVolume(pvc *corev1.PersistentVolumeClaim) string {
	if pvc == nil {
		return ""
	}
	return pvc.Spec.VolumeName
}

func firstRestartCount(pod *corev1.Pod) int32 {
	if pod == nil || len(pod.Status.ContainerStatuses) == 0 {
		return 0
	}
	return pod.Status.ContainerStatuses[0].RestartCount
}

func podSummary(pod *corev1.Pod) string {
	if pod == nil {
		return "pod unavailable"
	}
	parts := []string{fmt.Sprintf("phase=%s", pod.Status.Phase)}
	for _, status := range pod.Status.InitContainerStatuses {
		parts = append(parts, fmt.Sprintf("init/%s:%s:ready=%t:restart=%d", status.Name, containerStateName(status.State), status.Ready, status.RestartCount))
	}
	for _, status := range pod.Status.ContainerStatuses {
		parts = append(parts, fmt.Sprintf("%s:%s:ready=%t:restart=%d", status.Name, containerStateName(status.State), status.Ready, status.RestartCount))
	}
	return strings.Join(parts, "; ")
}

func containerStateName(state corev1.ContainerState) string {
	switch {
	case state.Running != nil:
		return "running"
	case state.Waiting != nil:
		return "waiting"
	case state.Terminated != nil:
		return "terminated"
	default:
		return "unknown"
	}
}

func podEvents(ctx context.Context, client *kubernetes.Clientset, ns, name string) string {
	list, err := client.CoreV1().Events(ns).List(ctx, metav1.ListOptions{FieldSelector: fields.OneTermEqualSelector("involvedObject.name", name).String()})
	if err != nil {
		return err.Error()
	}
	start := len(list.Items) - 6
	if start < 0 {
		start = 0
	}
	parts := make([]string, 0, len(list.Items)-start)
	for _, event := range list.Items[start:] {
		msg := strings.Join(strings.Fields(event.Message), " ")
		if len(msg) > 220 {
			msg = msg[:217] + "..."
		}
		parts = append(parts, event.Reason+": "+msg)
	}
	return strings.Join(parts, " | ")
}

func execInPod(ctx context.Context, cfg *envconf.Config, ns, pod, container string, command []string) (string, string, error) {
	restCfg := cfg.Client().RESTConfig()
	client, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return "", "", err
	}
	req := client.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(pod).
		Namespace(ns).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: container,
			Command:   command,
			Stdout:    true,
			Stderr:    true,
		}, scheme.ParameterCodec)

	exec, err := remoteExecutor(restCfg, req.URL())
	if err != nil {
		return "", "", err
	}
	return exec(ctx)
}

func remoteExecutor(restCfg *rest.Config, target *url.URL) (func(context.Context) (string, string, error), error) {
	executor, err := remotecommand.NewSPDYExecutor(restCfg, "POST", target)
	if err != nil {
		return nil, err
	}
	return func(ctx context.Context) (string, string, error) {
		var stdout, stderr bytes.Buffer
		err := executor.StreamWithContext(ctx, remotecommand.StreamOptions{
			Stdout: &stdout,
			Stderr: &stderr,
		})
		return stdout.String(), stderr.String(), err
	}, nil
}

func dnsName(value string) string {
	value = strings.ToLower(value)
	var b strings.Builder
	lastDash := false
	for _, r := range value {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if ok {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) > 63 {
		out = strings.Trim(out[:63], "-")
	}
	if out == "" {
		return "cube-kri-e2e"
	}
	return out
}

func int64Ptr(v int64) *int64 { return &v }
func boolPtr(v bool) *bool    { return &v }
func stringPtr(v string) *string {
	return &v
}
func hostPathTypePtr(v corev1.HostPathType) *corev1.HostPathType {
	return &v
}

func envString(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		parsed, err := strconv.ParseBool(v)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		parsed, err := strconv.Atoi(v)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		parsed, err := time.ParseDuration(v)
		if err == nil {
			return parsed
		}
		if seconds, err := strconv.Atoi(v); err == nil {
			return time.Duration(seconds) * time.Second
		}
	}
	return fallback
}
