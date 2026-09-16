// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func runtimeResourceTracing(ctx context.Context) (*sdktrace.TracerProvider, func(), error) {
	endpoint := os.Getenv("CUBE_CRI_TRACING_OTLP_ENDPOINT")
	if endpoint == "" {
		return nil, nil, nil
	}
	if protocol := os.Getenv("CUBE_CRI_TRACING_OTLP_PROTOCOL"); protocol != "" && protocol != "http/protobuf" {
		return nil, nil, fmt.Errorf("unsupported RuntimeResource trace protocol: %s", protocol)
	}
	ratio := 0.1
	if value := os.Getenv("CUBE_CRI_TRACING_SAMPLING_RATIO"); value != "" {
		parsed, err := strconv.ParseFloat(value, 64)
		if err != nil || math.IsNaN(parsed) || parsed < 0 || parsed > 1 {
			return nil, nil, fmt.Errorf("invalid RuntimeResource trace sampling ratio: %q", value)
		}
		ratio = parsed
	}
	endpoint = strings.TrimSuffix(strings.TrimRight(endpoint, "/"), "/v1/traces") + "/v1/traces"
	exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(endpoint))
	if err != nil {
		return nil, nil, err
	}
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))),
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(resource.NewWithAttributes("", attribute.String("service.name", "cube-cri-runtime-resource"))),
	)
	shutdown := func() {
		flushCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := provider.Shutdown(flushCtx); err != nil {
			fmt.Fprintf(os.Stderr, "RuntimeResource trace shutdown: %v\n", err)
		}
	}
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return provider, shutdown, nil
}
