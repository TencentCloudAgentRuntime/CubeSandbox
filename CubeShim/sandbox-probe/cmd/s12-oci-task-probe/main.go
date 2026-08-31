// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s12-oci-task-probe verifies that a containerd OCI image and overlayfs
// snapshot can create ordinary Tasks inside one already-running Cube sandbox.
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	controllerapi "github.com/containerd/containerd/api/services/sandbox/v1"
	tasksapi "github.com/containerd/containerd/api/services/tasks/v1"
	containerd "github.com/containerd/containerd/v2/client"
	coresandbox "github.com/containerd/containerd/v2/core/sandbox"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	"github.com/containerd/errdefs/pkg/errgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	grpcstatus "google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/anypb"
)

const (
	probeNamespace = "s12-live"
	sandboxer      = "shim"
	runtimeName    = "io.containerd.cube.rs"
	snapshotter    = "overlayfs"
)

func main() {
	if len(os.Args) != 6 {
		panic("usage: s12-oci-task-probe CONTAINERD_SOCKET STATE_DIR NETNS_PATH SANDBOX_ID IMAGE_REF")
	}
	socket, stateDir, netnsPath, sandboxID, imageRef := os.Args[1], os.Args[2], os.Args[3], os.Args[4], os.Args[5]
	for name, value := range map[string]string{
		"containerd socket": socket,
		"state dir":         stateDir,
		"netns path":        netnsPath,
		"sandbox ID":        sandboxID,
		"image reference":   imageRef,
	} {
		if strings.TrimSpace(value) == "" {
			panic(name + " is empty")
		}
	}
	if !filepath.IsAbs(stateDir) || !filepath.IsAbs(netnsPath) {
		panic("state dir and netns path must be absolute")
	}
	if _, err := os.Stat(netnsPath); err != nil {
		panic(fmt.Sprintf("netns path: %v", err))
	}

	client, err := containerd.New(socket)
	must(err)
	defer client.Close()

	connection, err := grpc.NewClient("passthrough:///containerd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		}),
	)
	must(err)
	defer connection.Close()
	controller := controllerapi.NewControllerClient(connection)

	preflightSandbox(client, controller, sandboxID)
	image := loadUnpackedImage(client, imageRef)
	bundle := filepath.Join(stateDir, "io.containerd.sandbox.controller.v1.shim", probeNamespace, sandboxID)

	stored := createSandboxMetadata(client, sandboxID)
	storeOwned, controllerOwned, shutdown := true, false, false
	defer func() {
		if controllerOwned && !shutdown {
			ctx, cancel := controllerContext(30 * time.Second)
			_, stopErr := controller.Stop(ctx, &controllerapi.ControllerStopRequest{
				SandboxID: sandboxID,
				Sandboxer: sandboxer,
			})
			cancel()
			if stopErr != nil {
				fmt.Fprintf(os.Stderr, "S12_CLEANUP_STOP_ERROR sandbox=%s error=%v\n", sandboxID, stopErr)
			}
			ctx, cancel = controllerContext(30 * time.Second)
			_, shutdownErr := controller.Shutdown(ctx, &controllerapi.ControllerShutdownRequest{
				SandboxID: sandboxID,
				Sandboxer: sandboxer,
			})
			cancel()
			if shutdownErr != nil {
				fmt.Fprintf(os.Stderr, "S12_CLEANUP_SHUTDOWN_ERROR sandbox=%s error=%v\n", sandboxID, shutdownErr)
			}
		}
		if storeOwned {
			ctx, cancel := clientContext(30 * time.Second)
			deleteErr := client.SandboxStore().Delete(ctx, sandboxID)
			cancel()
			if deleteErr != nil && !errdefs.IsNotFound(deleteErr) {
				fmt.Fprintf(os.Stderr, "S12_CLEANUP_STORE_ERROR sandbox=%s error=%v\n", sandboxID, deleteErr)
			}
		}
	}()

	ctx, cancel := controllerContext(2 * time.Minute)
	create, err := controller.Create(ctx, &controllerapi.ControllerCreateRequest{
		SandboxID:   sandboxID,
		Options:     &anypb.Any{TypeUrl: "runtime.v1.PodSandboxConfig", Value: criPodSandboxConfig()},
		NetnsPath:   netnsPath,
		Annotations: map[string]string{"s12.cubesandbox.io/oci-task": "true"},
		Sandboxer:   sandboxer,
		Sandbox:     coresandbox.ToProto(&stored),
	})
	cancel()
	controllerOwned = !createCollision(err, bundle)
	must(err)
	if create.GetSandboxID() != sandboxID {
		panic(fmt.Sprintf("Create sandbox ID = %q, want %q", create.GetSandboxID(), sandboxID))
	}
	must(waitFor(30*time.Second, func() bool { return directory(bundle) }))

	ctx, cancel = controllerContext(3 * time.Minute)
	started, err := controller.Start(ctx, &controllerapi.ControllerStartRequest{
		SandboxID: sandboxID,
		Sandboxer: sandboxer,
	})
	cancel()
	must(err)
	if started.GetPid() == 0 || started.GetCreatedAt() == nil {
		panic(fmt.Sprintf("invalid Sandbox Start response pid=%d created_at=%v", started.GetPid(), started.GetCreatedAt()))
	}

	ctx, cancel = clientContext(30 * time.Second)
	sandbox, err := client.LoadSandbox(ctx, sandboxID)
	cancel()
	must(err)
	if sandbox.ID() != sandboxID || sandbox.Metadata().Runtime.Name != runtimeName {
		panic(fmt.Sprintf("invalid loaded sandbox metadata: %+v", sandbox.Metadata()))
	}

	sharedRoot := runNaturalExitTask(client, sandbox, image, sandboxID+"-exit")
	secondSharedRoot := runKilledTask(client, sandbox, image, sandboxID+"-kill")
	if secondSharedRoot != sharedRoot {
		panic(fmt.Sprintf("Tasks used different shared roots: %q and %q", sharedRoot, secondSharedRoot))
	}
	if !directory(sharedRoot) {
		panic("RuntimeResource shared root disappeared before Sandbox Stop: " + sharedRoot)
	}

	ctx, cancel = controllerContext(2 * time.Minute)
	_, err = controller.Stop(ctx, &controllerapi.ControllerStopRequest{
		SandboxID:   sandboxID,
		TimeoutSecs: 30,
		Sandboxer:   sandboxer,
	})
	cancel()
	must(err)

	ctx, cancel = clientContext(30 * time.Second)
	waited, err := sandbox.Wait(ctx)
	must(err)
	exit := <-waited
	cancel()
	code, exitedAt, err := exit.Result()
	must(err)
	if code != 0 || exitedAt.IsZero() {
		panic(fmt.Sprintf("invalid Sandbox Wait response exit=%d exited_at=%v", code, exitedAt))
	}

	ctx, cancel = clientContext(30 * time.Second)
	err = sandbox.Shutdown(ctx)
	cancel()
	must(err)
	shutdown, controllerOwned, storeOwned = true, false, false
	must(waitFor(60*time.Second, func() bool {
		_, statErr := os.Stat(bundle)
		return errors.Is(statErr, os.ErrNotExist)
	}))

	fmt.Printf("S12_OCI_TASK_OK sandbox=%s image=%s shared_root=%s pid=%d exit=23 killed=137\n",
		sandboxID, imageRef, sharedRoot, started.GetPid())
}

func preflightSandbox(client *containerd.Client, controller controllerapi.ControllerClient, sandboxID string) {
	ctx, cancel := clientContext(30 * time.Second)
	_, err := client.LoadSandbox(ctx, sandboxID)
	cancel()
	if err == nil || !errdefs.IsNotFound(err) {
		panic(fmt.Sprintf("sandbox metadata ID is already in use or unavailable: %v", err))
	}

	ctx, cancel = controllerContext(30 * time.Second)
	status, err := controller.Status(ctx, &controllerapi.ControllerStatusRequest{
		SandboxID: sandboxID,
		Sandboxer: sandboxer,
	})
	cancel()
	must(err)
	if status.GetState() != "" || status.GetPid() != 0 {
		panic(fmt.Sprintf("sandbox runtime ID is already in use: state=%q pid=%d", status.GetState(), status.GetPid()))
	}
}

func loadUnpackedImage(client *containerd.Client, imageRef string) containerd.Image {
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	image, err := client.GetImage(ctx, imageRef)
	must(err)
	unpacked, err := image.IsUnpacked(ctx, snapshotter)
	must(err)
	if !unpacked {
		panic(fmt.Sprintf("image %s is not unpacked for %s", imageRef, snapshotter))
	}
	return image
}

func createSandboxMetadata(client *containerd.Client, sandboxID string) coresandbox.Sandbox {
	now := time.Now().UTC()
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	stored, err := client.SandboxStore().Create(ctx, coresandbox.Sandbox{
		ID:        sandboxID,
		Sandboxer: sandboxer,
		Runtime:   coresandbox.RuntimeOpts{Name: runtimeName},
		Labels:    map[string]string{"s12.cubesandbox.io/owned": "true"},
		CreatedAt: now,
		UpdatedAt: now,
	})
	must(err)
	return stored
}

func runNaturalExitTask(client *containerd.Client, sandbox containerd.Sandbox, image containerd.Image, taskID string) string {
	var stdout, stderr bytes.Buffer
	container := createContainer(sandbox, image, taskID,
		oci.WithProcessArgs("sh", "-c", "printf 'cube-s12-natural-exit\\n'; exit 23"))
	containerOwned := true
	defer func() {
		if containerOwned {
			deleteContainerBestEffort(container)
		}
	}()

	ctx, cancel := clientContext(2 * time.Minute)
	task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStreams(nil, &stdout, &stderr)))
	cancel()
	if err != nil {
		recoverErr := recoverAmbiguousTask(client, container)
		if recoverErr != nil {
			panic(fmt.Sprintf("NewTask: %v; recover possible Task: %v", err, recoverErr))
		}
		panic(err)
	}
	taskOwned := true
	defer func() {
		if taskOwned {
			deleteTaskBestEffort(client, task)
		}
	}()
	assertTaskStatus(task, containerd.Created)
	sharedRoot := assertTaskMountsPresent(taskID)

	waitCtx, waitCancel := clientContext(2 * time.Minute)
	waited, err := task.Wait(waitCtx)
	must(err)
	ctx, cancel = clientContext(30 * time.Second)
	err = task.Start(ctx)
	cancel()
	must(err)
	exit := <-waited
	waitCancel()
	code, exitedAt, err := exit.Result()
	must(err)
	if code != 23 || exitedAt.IsZero() {
		panic(fmt.Sprintf("natural task Wait exit=%d exited_at=%v stderr=%q", code, exitedAt, stderr.String()))
	}
	assertTaskStatus(task, containerd.Stopped)

	ctx, cancel = clientContext(2 * time.Minute)
	deleted, err := task.Delete(ctx)
	cancel()
	must(err)
	deleteCode, deleteTime, err := deleted.Result()
	must(err)
	if deleteCode != 23 || deleteTime.IsZero() {
		panic(fmt.Sprintf("natural task Delete exit=%d exited_at=%v", deleteCode, deleteTime))
	}
	taskOwned = false
	assertTaskMountsRemoved(taskID, sharedRoot)
	if !strings.Contains(stdout.String(), "cube-s12-natural-exit") {
		panic(fmt.Sprintf("natural task stdout missing marker: stdout=%q stderr=%q", stdout.String(), stderr.String()))
	}

	ctx, cancel = clientContext(2 * time.Minute)
	err = container.Delete(ctx, containerd.WithSnapshotCleanup)
	cancel()
	must(err)
	containerOwned = false
	return sharedRoot
}

func runKilledTask(client *containerd.Client, sandbox containerd.Sandbox, image containerd.Image, taskID string) string {
	container := createContainer(sandbox, image, taskID,
		oci.WithProcessArgs("sh", "-c", "exec sleep 300"))
	containerOwned := true
	defer func() {
		if containerOwned {
			deleteContainerBestEffort(container)
		}
	}()

	ctx, cancel := clientContext(2 * time.Minute)
	task, err := container.NewTask(ctx, cio.NullIO)
	cancel()
	if err != nil {
		recoverErr := recoverAmbiguousTask(client, container)
		if recoverErr != nil {
			panic(fmt.Sprintf("NewTask: %v; recover possible Task: %v", err, recoverErr))
		}
		panic(err)
	}
	taskOwned := true
	defer func() {
		if taskOwned {
			deleteTaskBestEffort(client, task)
		}
	}()
	assertTaskStatus(task, containerd.Created)
	sharedRoot := assertTaskMountsPresent(taskID)

	waitCtx, waitCancel := clientContext(2 * time.Minute)
	waited, err := task.Wait(waitCtx)
	must(err)
	ctx, cancel = clientContext(30 * time.Second)
	err = task.Start(ctx)
	cancel()
	must(err)
	assertTaskStatus(task, containerd.Running)
	ctx, cancel = clientContext(30 * time.Second)
	err = task.Kill(ctx, syscall.SIGKILL)
	cancel()
	must(err)
	exit := <-waited
	waitCancel()
	code, exitedAt, err := exit.Result()
	must(err)
	if code != 137 || exitedAt.IsZero() {
		panic(fmt.Sprintf("killed task Wait exit=%d exited_at=%v", code, exitedAt))
	}
	assertTaskStatus(task, containerd.Stopped)

	ctx, cancel = clientContext(2 * time.Minute)
	deleted, err := task.Delete(ctx)
	cancel()
	must(err)
	deleteCode, deleteTime, err := deleted.Result()
	must(err)
	if deleteCode != 137 || deleteTime.IsZero() {
		panic(fmt.Sprintf("killed task Delete exit=%d exited_at=%v", deleteCode, deleteTime))
	}
	taskOwned = false
	assertTaskMountsRemoved(taskID, sharedRoot)

	ctx, cancel = clientContext(2 * time.Minute)
	err = container.Delete(ctx, containerd.WithSnapshotCleanup)
	cancel()
	must(err)
	containerOwned = false
	return sharedRoot
}

func createContainer(sandbox containerd.Sandbox, image containerd.Image, taskID string, process oci.SpecOpts) containerd.Container {
	ctx, cancel := clientContext(2 * time.Minute)
	defer cancel()
	container, err := sandbox.NewContainer(ctx, taskID,
		containerd.WithRuntime(runtimeName, nil),
		containerd.WithImage(image),
		containerd.WithSnapshotter(snapshotter),
		containerd.WithNewSnapshot(taskID+"-snapshot", image),
		containerd.WithNewSpec(oci.WithImageConfig(image), process),
	)
	must(err)
	return container
}

func assertTaskStatus(task containerd.Task, want containerd.ProcessStatus) {
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	status, err := task.Status(ctx)
	must(err)
	if status.Status != want {
		panic(fmt.Sprintf("Task %s status=%q, want %q", task.ID(), status.Status, want))
	}
}

func assertTaskMountsPresent(taskID string) string {
	targets, err := taskMountTargets(taskID)
	must(err)
	if len(targets) == 0 {
		panic("no standard rootfs mounts found for Task " + taskID)
	}
	sharedRoot, err := sharedRootFromMount(targets[0])
	must(err)
	for _, target := range targets[1:] {
		root, rootErr := sharedRootFromMount(target)
		must(rootErr)
		if root != sharedRoot {
			panic(fmt.Sprintf("Task %s mount roots differ: %q and %q", taskID, sharedRoot, root))
		}
	}
	return sharedRoot
}

func assertTaskMountsRemoved(taskID, sharedRoot string) {
	must(waitFor(30*time.Second, func() bool {
		targets, err := taskMountTargets(taskID)
		return err == nil && len(targets) == 0
	}))
	if !directory(sharedRoot) {
		panic("Task Delete removed Sandbox shared root: " + sharedRoot)
	}
}

func taskMountTargets(taskID string) ([]string, error) {
	file, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return taskMountTargetsFrom(file, taskID)
}

func taskMountTargetsFrom(reader io.Reader, taskID string) ([]string, error) {
	needle := "/rootfs/" + taskID + "-"
	var targets []string
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) > 4 && strings.Contains(fields[4], needle) {
			targets = append(targets, fields[4])
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	sort.Strings(targets)
	return targets, nil
}

func sharedRootFromMount(target string) (string, error) {
	index := strings.Index(target, "/rootfs/")
	if index <= 0 {
		return "", fmt.Errorf("mount target has no rootfs export component: %q", target)
	}
	return target[:index], nil
}

func createCollision(err error, bundle string) bool {
	if grpcstatus.Code(err) == codes.AlreadyExists {
		return true
	}
	if grpcstatus.Code(err) != codes.Unknown {
		return false
	}
	return strings.Contains(grpcstatus.Convert(err).Message(), "mkdir "+bundle+": file exists")
}

type cleanupProcess interface {
	ID() string
	IO() cio.IO
	Status(context.Context) (containerd.Status, error)
	Wait(context.Context) (<-chan containerd.ExitStatus, error)
	Kill(context.Context, syscall.Signal, ...containerd.KillOpts) error
	Delete(context.Context, ...containerd.ProcessDeleteOpts) (*containerd.ExitStatus, error)
}

func recoverAmbiguousTask(client *containerd.Client, container containerd.Container) error {
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	return recoverLoadedTask(
		ctx,
		func(ctx context.Context) (cleanupProcess, error) {
			return container.Task(ctx, nil)
		},
		func(task cleanupProcess) error {
			return cleanupTask(ctx, task, rawTaskDelete(client), cleanupDeleteContext)
		},
	)
}

func recoverLoadedTask(
	ctx context.Context,
	load func(context.Context) (cleanupProcess, error),
	cleanup func(cleanupProcess) error,
) error {
	task, err := load(ctx)
	if err != nil {
		if errdefs.IsNotFound(err) {
			return nil
		}
		return err
	}
	return cleanup(task)
}

func rawTaskDelete(client *containerd.Client) func(context.Context, string) error {
	return func(ctx context.Context, taskID string) error {
		_, err := client.TaskService().Delete(ctx, &tasksapi.DeleteTaskRequest{ContainerID: taskID})
		if err == nil {
			return nil
		}
		return errgrpc.ToNative(err)
	}
}

func cleanupTask(
	ctx context.Context,
	task cleanupProcess,
	rawDelete func(context.Context, string) error,
	freshDeleteContext func() (context.Context, context.CancelFunc),
) error {
	status, err := task.Status(ctx)
	if err != nil {
		if errdefs.IsNotFound(err) {
			closeTaskIO(task.IO())
			return nil
		}
		return err
	}

	if status.Status == containerd.Created {
		deleteCtx, cancel := freshDeleteContext()
		err := rawDelete(deleteCtx, task.ID())
		cancel()
		if err != nil && !errdefs.IsNotFound(err) {
			closeTaskIO(task.IO())
			return fmt.Errorf("delete Created Task through TaskService: %w", err)
		}
		closeTaskIO(task.IO())
		return nil
	}

	if status.Status == containerd.Running {
		waited, waitErr := task.Wait(ctx)
		if waitErr == nil {
			killErr := task.Kill(ctx, syscall.SIGKILL)
			if killErr == nil {
				select {
				case <-waited:
				case <-ctx.Done():
				}
			}
		}
	}

	deleteCtx, cancel := freshDeleteContext()
	_, err = task.Delete(deleteCtx)
	cancel()
	if err == nil {
		return nil
	}
	if errdefs.IsNotFound(err) {
		closeTaskIO(task.IO())
		return nil
	}
	rawCtx, rawCancel := freshDeleteContext()
	err = rawDelete(rawCtx, task.ID())
	rawCancel()
	if err != nil && !errdefs.IsNotFound(err) {
		return fmt.Errorf("fallback TaskService Delete: %w", err)
	}
	closeTaskIO(task.IO())
	return nil
}

func closeTaskIO(taskIO cio.IO) {
	if taskIO == nil {
		return
	}
	taskIO.Cancel()
	taskIO.Wait()
	_ = taskIO.Close()
}

func deleteTaskBestEffort(client *containerd.Client, task containerd.Task) {
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	if err := cleanupTask(ctx, task, rawTaskDelete(client), cleanupDeleteContext); err != nil {
		fmt.Fprintf(os.Stderr, "S12_CLEANUP_TASK_ERROR task=%s error=%v\n", task.ID(), err)
	}
}

func cleanupDeleteContext() (context.Context, context.CancelFunc) {
	return clientContext(30 * time.Second)
}

func deleteContainerBestEffort(container containerd.Container) {
	ctx, cancel := clientContext(30 * time.Second)
	defer cancel()
	_ = container.Delete(ctx, containerd.WithSnapshotCleanup)
}

func clientContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(namespaces.WithNamespace(context.Background(), probeNamespace), timeout)
}

func controllerContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	ctx := metadata.NewOutgoingContext(context.Background(), metadata.Pairs("containerd-namespace", probeNamespace))
	return context.WithTimeout(ctx, timeout)
}

func criPodSandboxConfig() []byte {
	meta := appendString(nil, 1, "s12-live")
	meta = appendString(meta, 2, "s12-live-uid")
	meta = appendString(meta, 3, "default")
	dns := appendString(nil, 1, "10.96.0.10")
	dns = appendString(dns, 2, "default.svc.cluster.local")
	dns = appendString(dns, 3, "ndots:5")
	annotation := appendString(nil, 1, "s12.cubesandbox.io/oci-task")
	annotation = appendString(annotation, 2, "true")
	config := appendMessage(nil, 1, meta)
	config = appendMessage(config, 4, dns)
	return appendMessage(config, 7, annotation)
}

func appendString(buffer []byte, field protowire.Number, value string) []byte {
	buffer = protowire.AppendTag(buffer, field, protowire.BytesType)
	return protowire.AppendString(buffer, value)
}

func appendMessage(buffer []byte, field protowire.Number, value []byte) []byte {
	buffer = protowire.AppendTag(buffer, field, protowire.BytesType)
	return protowire.AppendBytes(buffer, value)
}

func waitFor(timeout time.Duration, condition func() bool) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("timed out waiting for integration condition")
}

func directory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
