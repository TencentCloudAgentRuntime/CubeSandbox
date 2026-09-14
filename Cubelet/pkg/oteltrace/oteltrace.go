// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package oteltrace owns opt-in OpenTelemetry tracing for cubelet-cri.
package oteltrace

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"google.golang.org/grpc"
)

const (
	envEndpoint     = "CUBE_CRI_TRACING_OTLP_ENDPOINT"
	envProtocol     = "CUBE_CRI_TRACING_OTLP_PROTOCOL"
	envServiceName  = "CUBE_CRI_TRACING_SERVICE_NAME"
	envSampleRatio  = "CUBE_CRI_TRACING_SAMPLING_RATIO"
	envSDKDisabled  = "OTEL_SDK_DISABLED"
	envOTLPEndpoint = "OTEL_EXPORTER_OTLP_ENDPOINT"
	envOTLPProtocol = "OTEL_EXPORTER_OTLP_PROTOCOL"
	envOTLPTraces   = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"
	envServiceOTEL  = "OTEL_SERVICE_NAME"
)

// Config describes process-wide tracing settings. An empty endpoint keeps
// tracing disabled.
type Config struct {
	Endpoint    string
	Protocol    string
	ServiceName string
	SampleRatio float64
}

// FromEnv returns the opt-in tracing configuration.
func FromEnv(defaultServiceName string) (Config, error) {
	if disabled, err := strconv.ParseBool(os.Getenv(envSDKDisabled)); err == nil && disabled {
		return Config{}, nil
	}
	endpoint := firstNonEmpty(os.Getenv(envEndpoint), os.Getenv(envOTLPTraces), os.Getenv(envOTLPEndpoint))
	if endpoint == "" {
		return Config{}, nil
	}
	protocol := firstNonEmpty(os.Getenv(envProtocol), os.Getenv(envOTLPProtocol), "http/protobuf")
	serviceName := firstNonEmpty(os.Getenv(envServiceName), os.Getenv(envServiceOTEL), defaultServiceName)
	ratio := 1.0
	if raw := strings.TrimSpace(os.Getenv(envSampleRatio)); raw != "" {
		parsed, err := strconv.ParseFloat(raw, 64)
		if err != nil || parsed < 0 || parsed > 1 {
			return Config{}, fmt.Errorf("%s must be a number in [0,1]", envSampleRatio)
		}
		ratio = parsed
	}
	return Config{Endpoint: endpoint, Protocol: protocol, ServiceName: serviceName, SampleRatio: ratio}, nil
}

// Enabled reports whether tracing should be installed.
func (c Config) Enabled() bool {
	return c.Endpoint != ""
}

// Setup initializes OpenTelemetry for cubelet-cri. The returned function must
// be called during shutdown.
func Setup(ctx context.Context, cfg Config) (func(context.Context) error, error) {
	if !cfg.Enabled() {
		return func(context.Context) error { return nil }, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	exporter, err := newExporter(ctx, cfg)
	if err != nil {
		return nil, err
	}
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(cfg.SampleRatio))),
		sdktrace.WithResource(resource.NewWithAttributes(
			"",
			attribute.String("service.name", cfg.ServiceName),
		)),
	)
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return provider.Shutdown, nil
}

// GRPCServerOption instruments inbound RuntimeResource RPCs when tracing is on.
func GRPCServerOption(cfg Config) []grpc.ServerOption {
	if !cfg.Enabled() {
		return nil
	}
	return []grpc.ServerOption{grpc.StatsHandler(otelgrpc.NewServerHandler())}
}

func newExporter(ctx context.Context, cfg Config) (*otlptrace.Exporter, error) {
	switch cfg.Protocol {
	case "", "http/protobuf":
		return otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(cfg.Endpoint), otlptracehttp.WithTimeout(5*time.Second))
	case "grpc":
		return otlptracegrpc.New(ctx, otlptracegrpc.WithEndpointURL(cfg.Endpoint), otlptracegrpc.WithInsecure())
	default:
		return nil, fmt.Errorf("unsupported tracing protocol %q", cfg.Protocol)
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// Shutdown calls fn with a bounded context.
func Shutdown(fn func(context.Context) error) error {
	if fn == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := fn(ctx); err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	return nil
}
