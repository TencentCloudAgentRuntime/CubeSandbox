// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	gogoproto "github.com/gogo/protobuf/proto"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/oteltrace"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/tracebridge"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	oteltraceapi "go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const (
	defaultListen          = "/run/containerd/containerd.sock"
	defaultBackend         = "/run/containerd/containerd-real.sock"
	methodRunPodSandbox    = "/runtime.v1.RuntimeService/RunPodSandbox"
	methodCreateContainer  = "/runtime.v1.RuntimeService/CreateContainer"
	methodStartContainer   = "/runtime.v1.RuntimeService/StartContainer"
	methodPodSandboxStatus = "/runtime.v1.RuntimeService/PodSandboxStatus"
)

var clientStreamDesc = &grpc.StreamDesc{ServerStreams: true, ClientStreams: true}

type frame struct {
	payload []byte
}

type rawCodec struct{}

func (rawCodec) Marshal(v interface{}) ([]byte, error) {
	if f, ok := v.(*frame); ok {
		return f.payload, nil
	}
	return proto.Marshal(v.(proto.Message))
}

func (rawCodec) Unmarshal(data []byte, v interface{}) error {
	if f, ok := v.(*frame); ok {
		f.payload = data
		return nil
	}
	return proto.Unmarshal(data, v.(proto.Message))
}

func (rawCodec) String() string { return "cube-cri-trace-proxy" }

type proxyServer struct {
	backend *grpc.ClientConn
}

type bridgeCall struct {
	podUID      string
	sandboxID   string
	containerID string
}

func main() {
	listenPath := flag.String("listen", getenv("CUBE_CRI_TRACE_PROXY_LISTEN", defaultListen), "frontend containerd socket path")
	backendPath := flag.String("backend", getenv("CUBE_CRI_TRACE_PROXY_BACKEND", defaultBackend), "backend containerd socket path")
	flag.Parse()

	traceConfig, err := oteltrace.FromEnv("cube-cri-trace-proxy")
	if err != nil {
		log.Fatalf("load tracing config: %v", err)
	}
	shutdown, err := oteltrace.Setup(context.Background(), traceConfig)
	if err != nil {
		log.Fatalf("setup tracing: %v", err)
	}
	defer func() {
		if err := oteltrace.Shutdown(shutdown); err != nil {
			log.Printf("shutdown tracing: %v", err)
		}
	}()
	if !traceConfig.Enabled() {
		log.Printf("tracing is disabled; proxy will forward without bridge context")
	}

	conn, err := grpc.DialContext(
		context.Background(),
		"unix://"+*backendPath,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(unixDialer),
		grpc.WithDefaultCallOptions(grpc.CallCustomCodec(rawCodec{})),
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
	)
	if err != nil {
		log.Fatalf("dial backend containerd: %v", err)
	}
	defer conn.Close()

	if err := os.MkdirAll(filepath.Dir(*listenPath), 0o755); err != nil {
		log.Fatalf("create socket dir: %v", err)
	}
	if err := os.RemoveAll(*listenPath); err != nil {
		log.Fatalf("remove stale socket: %v", err)
	}
	listener, err := net.Listen("unix", *listenPath)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenPath, err)
	}
	defer listener.Close()
	if err := os.Chmod(*listenPath, 0o666); err != nil {
		log.Fatalf("chmod socket: %v", err)
	}

	server := grpc.NewServer(
		grpc.CustomCodec(rawCodec{}),
		grpc.UnknownServiceHandler((&proxyServer{backend: conn}).handle),
	)
	log.Printf("cube-cri-trace-proxy listening on %s and forwarding to %s", *listenPath, *backendPath)
	if err := server.Serve(listener); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func (p *proxyServer) handle(_ interface{}, serverStream grpc.ServerStream) error {
	fullMethodName, ok := grpc.MethodFromServerStream(serverStream)
	if !ok {
		return status.Error(codes.Internal, "missing full method name")
	}
	ctx := serverStream.Context()
	var firstRequest *frame
	var bridge *bridgeCall
	var spanEnd func(error)
	if shouldTrace(fullMethodName) {
		firstRequest = &frame{}
		if err := serverStream.RecvMsg(firstRequest); err != nil {
			return err
		}
		ctx, bridge = bridgeContextForRequest(fullMethodName, ctx, firstRequest.payload)
		tracer := otel.Tracer("cube-cri-trace-proxy")
		var span oteltraceapi.Span
		ctx, span = tracer.Start(ctx, "cube-cri.trace_proxy."+methodName(fullMethodName),
			oteltraceapi.WithAttributes(
				attribute.String("rpc.system", "grpc"),
				attribute.String("rpc.service", serviceName(fullMethodName)),
				attribute.String("rpc.method", methodName(fullMethodName)),
			),
		)
		if bridge != nil {
			span.SetAttributes(bridge.attributes()...)
			bridge.storeRequestContext(fullMethodName, ctx)
		}
		spanEnd = func(err error) {
			if err != nil {
				span.RecordError(err)
				span.SetStatus(otelcodes.Error, err.Error())
			}
			span.End()
		}
	} else {
		spanEnd = func(error) {}
	}
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		ctx = metadata.NewOutgoingContext(ctx, md.Copy())
	}

	clientCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	clientStream, err := grpc.NewClientStream(clientCtx, clientStreamDesc, p.backend, fullMethodName, grpc.CallCustomCodec(rawCodec{}))
	if err != nil {
		spanEnd(err)
		return err
	}
	if firstRequest != nil {
		if err := clientStream.SendMsg(firstRequest); err != nil {
			spanEnd(err)
			return err
		}
	}
	s2cErr := forwardRemainingServerToClient(serverStream, clientStream)
	c2sErr := forwardClientToServer(fullMethodName, ctx, bridge, clientStream, serverStream)
	for i := 0; i < 2; i++ {
		select {
		case err := <-s2cErr:
			if errors.Is(err, io.EOF) {
				if closeErr := clientStream.CloseSend(); closeErr != nil {
					spanEnd(closeErr)
					return closeErr
				}
				continue
			}
			cancel()
			wrapped := status.Errorf(codes.Internal, "proxy client to backend: %v", err)
			spanEnd(wrapped)
			return wrapped
		case err := <-c2sErr:
			serverStream.SetTrailer(clientStream.Trailer())
			if errors.Is(err, io.EOF) {
				spanEnd(nil)
				return nil
			}
			spanEnd(err)
			return err
		}
	}
	err = status.Error(codes.Internal, "proxy loop ended unexpectedly")
	spanEnd(err)
	return err
}

func forwardRemainingServerToClient(src grpc.ServerStream, dst grpc.ClientStream) chan error {
	ret := make(chan error, 1)
	go func() {
		for {
			f := &frame{}
			if err := src.RecvMsg(f); err != nil {
				ret <- err
				return
			}
			if err := dst.SendMsg(f); err != nil {
				ret <- err
				return
			}
		}
	}()
	return ret
}

func forwardClientToServer(fullMethodName string, ctx context.Context, bridge *bridgeCall, src grpc.ClientStream, dst grpc.ServerStream) chan error {
	ret := make(chan error, 1)
	go func() {
		for i := 0; ; i++ {
			f := &frame{}
			if err := src.RecvMsg(f); err != nil {
				ret <- err
				return
			}
			if i == 0 {
				md, err := src.Header()
				if err != nil {
					ret <- err
					return
				}
				if err := dst.SendHeader(md); err != nil {
					ret <- err
					return
				}
				if bridge != nil {
					bridge.storeResponseContext(fullMethodName, ctx, f.payload)
				}
			}
			if err := dst.SendMsg(f); err != nil {
				ret <- err
				return
			}
		}
	}()
	return ret
}

func bridgeContextForRequest(fullMethodName string, ctx context.Context, payload []byte) (context.Context, *bridgeCall) {
	bridge := &bridgeCall{}
	switch fullMethodName {
	case methodRunPodSandbox:
		request := &runtimeapi.RunPodSandboxRequest{}
		if err := gogoproto.Unmarshal(payload, request); err != nil {
			log.Printf("decode RunPodSandbox for trace bridge: %v", err)
			return ctx, bridge
		}
		bridge.podUID = request.GetConfig().GetMetadata().GetUid()
	case methodCreateContainer:
		request := &runtimeapi.CreateContainerRequest{}
		if err := gogoproto.Unmarshal(payload, request); err != nil {
			log.Printf("decode CreateContainer for trace bridge: %v", err)
			return ctx, bridge
		}
		bridge.sandboxID = request.GetPodSandboxId()
		if bridge.sandboxID != "" {
			ctx = tracebridge.ContextForKey(ctx, sandboxTraceKey(bridge.sandboxID))
		}
	case methodStartContainer:
		request := &runtimeapi.StartContainerRequest{}
		if err := gogoproto.Unmarshal(payload, request); err != nil {
			log.Printf("decode StartContainer for trace bridge: %v", err)
			return ctx, bridge
		}
		bridge.containerID = request.GetContainerId()
		if bridge.containerID != "" {
			ctx = tracebridge.ContextForKey(ctx, containerTraceKey(bridge.containerID))
		}
	case methodPodSandboxStatus:
		request := &runtimeapi.PodSandboxStatusRequest{}
		if err := gogoproto.Unmarshal(payload, request); err != nil {
			log.Printf("decode PodSandboxStatus for trace bridge: %v", err)
			return ctx, bridge
		}
		bridge.sandboxID = request.GetPodSandboxId()
		if bridge.sandboxID != "" {
			ctx = tracebridge.ContextForKey(ctx, sandboxTraceKey(bridge.sandboxID))
		}
	}
	return ctx, bridge
}

func (b *bridgeCall) attributes() []attribute.KeyValue {
	if b == nil {
		return nil
	}
	attrs := make([]attribute.KeyValue, 0, 3)
	if b.podUID != "" {
		attrs = append(attrs, attribute.String("pod.uid", b.podUID))
	}
	if b.sandboxID != "" {
		attrs = append(attrs, attribute.String("sandbox.id", b.sandboxID))
	}
	if b.containerID != "" {
		attrs = append(attrs, attribute.String("container.id", b.containerID))
	}
	return attrs
}

func (b *bridgeCall) storeRequestContext(fullMethodName string, ctx context.Context) {
	if b == nil || fullMethodName != methodRunPodSandbox || b.podUID == "" {
		return
	}
	if err := tracebridge.StoreContext(ctx, b.podUID, 10*time.Minute); err != nil {
		log.Printf("store trace bridge context pod_uid=%s: %v", b.podUID, err)
	}
}

func (b *bridgeCall) storeResponseContext(fullMethodName string, ctx context.Context, payload []byte) {
	if b == nil {
		return
	}
	switch fullMethodName {
	case methodRunPodSandbox:
		response := &runtimeapi.RunPodSandboxResponse{}
		if err := gogoproto.Unmarshal(payload, response); err != nil {
			log.Printf("decode RunPodSandbox response for trace bridge: %v", err)
			return
		}
		b.sandboxID = response.GetPodSandboxId()
		if b.sandboxID != "" {
			if err := tracebridge.StoreContextKey(ctx, sandboxTraceKey(b.sandboxID), 10*time.Minute); err != nil {
				log.Printf("store trace bridge context sandbox_id=%s: %v", b.sandboxID, err)
			}
		}
	case methodCreateContainer:
		response := &runtimeapi.CreateContainerResponse{}
		if err := gogoproto.Unmarshal(payload, response); err != nil {
			log.Printf("decode CreateContainer response for trace bridge: %v", err)
			return
		}
		b.containerID = response.GetContainerId()
		if b.containerID != "" {
			if err := tracebridge.StoreContextKey(ctx, containerTraceKey(b.containerID), 10*time.Minute); err != nil {
				log.Printf("store trace bridge context container_id=%s: %v", b.containerID, err)
			}
		}
	}
}

func sandboxTraceKey(sandboxID string) string {
	return "sandbox." + sandboxID
}

func containerTraceKey(containerID string) string {
	return "container." + containerID
}

func shouldTrace(fullMethodName string) bool {
	switch fullMethodName {
	case methodRunPodSandbox, methodCreateContainer, methodStartContainer, methodPodSandboxStatus:
		return true
	default:
		return false
	}
}

func unixDialer(ctx context.Context, target string) (net.Conn, error) {
	target = strings.TrimPrefix(target, "unix://")
	dialer := &net.Dialer{}
	return dialer.DialContext(ctx, "unix", target)
}

func getenv(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func serviceName(fullMethodName string) string {
	parts := strings.Split(strings.TrimPrefix(fullMethodName, "/"), "/")
	if len(parts) > 0 {
		return parts[0]
	}
	return ""
}

func methodName(fullMethodName string) string {
	parts := strings.Split(strings.TrimPrefix(fullMethodName, "/"), "/")
	if len(parts) > 1 {
		return parts[1]
	}
	return fmt.Sprintf("%q", fullMethodName)
}
