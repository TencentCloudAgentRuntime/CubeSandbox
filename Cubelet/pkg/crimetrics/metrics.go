// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package crimetrics owns the bounded-cardinality metrics exported by
// cubelet-cri. Sandbox and container identities belong in logs, never labels.
package crimetrics

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
)

var durationBuckets = []float64{0.0001, 0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120}

// Metrics is intentionally node scoped. All labels are validated finite sets.
type Metrics struct {
	operations    *prometheus.CounterVec
	durations     *prometheus.HistogramVec
	failures      *prometheus.CounterVec
	inflight      *prometheus.GaugeVec
	lockWait      *prometheus.HistogramVec
	rpcs          *prometheus.CounterVec
	rpcDuration   *prometheus.HistogramVec
	rpcInflight   *prometheus.GaugeVec
	leases        *prometheus.GaugeVec
	reaperPending prometheus.Gauge
	reaperOldest  prometheus.Gauge
	scanSuccess   prometheus.Gauge
	scanTimestamp prometheus.Gauge
	events        *prometheus.CounterVec
	eventsDropped prometheus.Counter
	eventMu       sync.Mutex
	eventInflight map[string]int
}

func New(registerer prometheus.Registerer) *Metrics {
	m := &Metrics{
		operations:    prometheus.NewCounterVec(prometheus.CounterOpts{Name: "cube_cri_operations_total", Help: "Completed Cube CRI internal operations."}, []string{"component", "operation", "result"}),
		durations:     prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "cube_cri_operation_duration_seconds", Help: "Duration of Cube CRI internal operations; nested operations can overlap.", Buckets: durationBuckets}, []string{"component", "operation", "result"}),
		failures:      prometheus.NewCounterVec(prometheus.CounterOpts{Name: "cube_cri_operation_failures_total", Help: "Failed Cube CRI internal operations by stable error class."}, []string{"component", "operation", "error_class"}),
		inflight:      prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "cube_cri_operations_inflight", Help: "Cube CRI internal operations currently in progress."}, []string{"component", "operation"}),
		lockWait:      prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "cube_cri_lock_wait_duration_seconds", Help: "Time spent waiting for Cube CRI locks.", Buckets: durationBuckets}, []string{"lock"}),
		rpcs:          prometheus.NewCounterVec(prometheus.CounterOpts{Name: "cube_cri_rpc_requests_total", Help: "Completed RuntimeResource RPCs by gRPC code."}, []string{"method", "code"}),
		rpcDuration:   prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "cube_cri_rpc_duration_seconds", Help: "RuntimeResource RPC duration including lock wait.", Buckets: durationBuckets}, []string{"method"}),
		rpcInflight:   prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "cube_cri_rpc_inflight", Help: "RuntimeResource RPCs currently in progress."}, []string{"method"}),
		leases:        prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "cube_cri_resource_leases", Help: "Cached durable RuntimeResource lease count by phase."}, []string{"phase"}),
		reaperPending: prometheus.NewGauge(prometheus.GaugeOpts{Name: "cube_cri_reaper_pending_jobs", Help: "Cached count of durable RuntimeResource cleanup jobs."}),
		reaperOldest:  prometheus.NewGauge(prometheus.GaugeOpts{Name: "cube_cri_reaper_oldest_job_timestamp_seconds", Help: "Oldest durable cleanup job modification time, or zero when none exist."}),
		scanSuccess:   prometheus.NewGauge(prometheus.GaugeOpts{Name: "cube_cri_state_collection_success", Help: "Whether the latest background state collection succeeded."}),
		scanTimestamp: prometheus.NewGauge(prometheus.GaugeOpts{Name: "cube_cri_state_collection_timestamp_seconds", Help: "Unix time of the last successful background state collection."}),
		events:        prometheus.NewCounterVec(prometheus.CounterOpts{Name: "cube_cri_metric_events_total", Help: "Shim and VMM worker metric events by validation result."}, []string{"result"}),
		eventsDropped: prometheus.NewCounter(prometheus.CounterOpts{Name: "cube_cri_metric_events_dropped_total", Help: "Metric events dropped by Shim or VMM worker before delivery."}),
		eventInflight: map[string]int{},
	}
	registerer.MustRegister(m.operations, m.durations, m.failures, m.inflight, m.lockWait, m.rpcs, m.rpcDuration, m.rpcInflight, m.leases, m.reaperPending, m.reaperOldest, m.scanSuccess, m.scanTimestamp, m.events, m.eventsDropped)
	return m
}

func (m *Metrics) Start(component, operation string) func(error) {
	if m == nil || !validOperation(component, operation) {
		return func(error) {}
	}
	started := time.Now()
	m.inflight.WithLabelValues(component, operation).Inc()
	return func(err error) {
		result := "ok"
		if err != nil {
			result = "error"
			m.failures.WithLabelValues(component, operation, "internal").Inc()
		}
		m.operations.WithLabelValues(component, operation, result).Inc()
		m.durations.WithLabelValues(component, operation, result).Observe(time.Since(started).Seconds())
		m.inflight.WithLabelValues(component, operation).Dec()
	}
}

func (m *Metrics) Observe(component, operation, result, errorClass string, seconds float64) {
	if m == nil || !validOperation(component, operation) || !validResult(result) || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 {
		return
	}
	m.operations.WithLabelValues(component, operation, result).Inc()
	m.durations.WithLabelValues(component, operation, result).Observe(seconds)
	if result != "ok" {
		if !validErrorClass(errorClass) {
			errorClass = "internal"
		}
		m.failures.WithLabelValues(component, operation, errorClass).Inc()
	}
}

func (m *Metrics) ObserveLockWait(lock string, started time.Time) {
	if m != nil && (lock == "sandbox_operation" || lock == "node_adapter") {
		m.lockWait.WithLabelValues(lock).Observe(time.Since(started).Seconds())
	}
}

func (m *Metrics) SetLeaseCount(phase string, value float64) {
	if m != nil && (phase == "PREPARING" || phase == "READY" || phase == "RELEASING" || phase == "UNKNOWN") {
		m.leases.WithLabelValues(phase).Set(value)
	}
}

func (m *Metrics) SetReaper(pending, oldest float64) {
	if m != nil {
		m.reaperPending.Set(pending)
		m.reaperOldest.Set(oldest)
	}
}

func (m *Metrics) SetStateCollection(success bool, timestamp time.Time) {
	if m == nil {
		return
	}
	if success {
		m.scanSuccess.Set(1)
		m.scanTimestamp.Set(float64(timestamp.Unix()))
	} else {
		m.scanSuccess.Set(0)
	}
}

func (m *Metrics) UnaryInterceptor(ctx context.Context, request any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (response any, err error) {
	method := rpcMethod(info.FullMethod)
	started := time.Now()
	m.rpcInflight.WithLabelValues(method).Inc()
	defer func() {
		m.rpcs.WithLabelValues(method, status.Code(err).String()).Inc()
		m.rpcDuration.WithLabelValues(method).Observe(time.Since(started).Seconds())
		m.rpcInflight.WithLabelValues(method).Dec()
	}()
	return handler(ctx, request)
}

func rpcMethod(method string) string {
	name := method[strings.LastIndex(method, "/")+1:]
	switch name {
	case "GetCapabilities", "PrepareSandbox", "ReleaseSandbox", "InspectSandbox", "ReconcileSandboxes":
		return name
	}
	return "other"
}

type event struct {
	Version         int     `json:"version"`
	EventType       string  `json:"event_type,omitempty"`
	Component       string  `json:"component"`
	Operation       string  `json:"operation"`
	Result          string  `json:"result"`
	ErrorClass      string  `json:"error_class,omitempty"`
	DurationSeconds float64 `json:"duration_seconds"`
	Dropped         uint64  `json:"dropped,omitempty"`
}

// ListenEvents accepts best-effort observations from root-owned Shim and worker
// processes. Socket file permissions enforce the producer boundary.
func (m *Metrics) ListenEvents(path string) (*net.UnixConn, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("metrics endpoint %q is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		listener.Close()
		return nil, err
	}
	go func() {
		buffer := make([]byte, 1025)
		for {
			n, _, err := listener.ReadFromUnix(buffer)
			if err != nil {
				return
			}
			m.acceptEvent(buffer[:n])
		}
	}()
	return listener, nil
}

func (m *Metrics) acceptEvent(data []byte) {
	var observation event
	if len(data) > 1024 || json.Unmarshal(data, &observation) != nil || observation.Version != 1 || !validOperation(observation.Component, observation.Operation) {
		m.events.WithLabelValues("invalid").Inc()
		return
	}
	switch observation.EventType {
	case "start":
		if observation.Result != "" || observation.DurationSeconds != 0 {
			m.events.WithLabelValues("invalid").Inc()
			return
		}
		m.startEventOperation(observation.Component, observation.Operation)
	case "", "observe", "finish": // empty is emitted by pre-inflight Shims.
		if !validResult(observation.Result) || math.IsNaN(observation.DurationSeconds) || math.IsInf(observation.DurationSeconds, 0) || observation.DurationSeconds < 0 {
			m.events.WithLabelValues("invalid").Inc()
			return
		}
		m.Observe(observation.Component, observation.Operation, observation.Result, observation.ErrorClass, observation.DurationSeconds)
		if observation.EventType == "finish" {
			m.finishEventOperation(observation.Component, observation.Operation)
		}
	default:
		m.events.WithLabelValues("invalid").Inc()
		return
	}
	m.eventsDropped.Add(float64(observation.Dropped))
	m.events.WithLabelValues("accepted").Inc()
}

// Start/finish observations come from the same datagram listener. The local
// count prevents an out-of-order or dropped start from producing a negative
// Gauge. When event drops are non-zero, the dashboard marks this signal as
// lossy rather than treating it as an exact queue length.
func (m *Metrics) startEventOperation(component, operation string) {
	key := component + "\x00" + operation
	m.eventMu.Lock()
	m.eventInflight[key]++
	m.eventMu.Unlock()
	m.inflight.WithLabelValues(component, operation).Inc()
}

func (m *Metrics) finishEventOperation(component, operation string) {
	key := component + "\x00" + operation
	m.eventMu.Lock()
	if m.eventInflight[key] == 0 {
		m.eventMu.Unlock()
		return
	}
	m.eventInflight[key]--
	m.eventMu.Unlock()
	m.inflight.WithLabelValues(component, operation).Dec()
}

func validResult(value string) bool { return value == "ok" || value == "error" || value == "canceled" }
func validErrorClass(value string) bool {
	switch value {
	case "kvm", "network", "state", "agent", "timeout", "cgroup", "validation", "internal":
		return true
	}
	return false
}
func validOperation(component, operation string) bool {
	allowed := map[string]map[string]bool{
		"resource": {"Prepare": true, "Release": true, "NetworkPrepare": true, "NetworkRelease": true, "Persist": true, "SharedRootCleanup": true, "ReaperScan": true, "Inspect": true},
		"shim":     {"CreatePodSandbox": true, "TemplateDerivedSandbox": true, "ColdStartSandbox": true, "TaskCreate": true, "TaskStart": true, "StartSandbox": true, "StopSandbox": true, "ShutdownSandbox": true, "CreatePodContainer": true, "Start": true, "DeleteContainer": true, "Exec": true, "Stats": true, "WorkerSpawn": true, "WorkerExit": true, "VmmReady": true, "VmConfig": true, "VmmLaunch": true, "VmBoot": true, "GuestKernelBoot": true, "GuestKernelInit": true, "GuestInitSetup": true, "GuestAgentExec": true, "AgentServerStart": true, "VsockReady": true, "AgentConnect": true, "GuestDeviceSetup": true, "MonitorSetup": true},
		"vmm":      {"prepare-intent": true, "fork-exec": true, "hello": true, "fd-gate": true, "placement": true, "launch": true, "LaunchVmm": true, "CreateVm": true, "BootVm": true, "RestoreVm": true},
		"agent":    {"CreateSandbox": true, "CreateContainer": true, "StartContainer": true},
	}
	return allowed[component][operation]
}
