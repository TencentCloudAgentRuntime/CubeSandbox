package crimetrics

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func TestValidOperationIncludesTaskLifecycle(t *testing.T) {
	for _, metric := range []struct{ component, operation string }{
		{"shim", "TaskCreate"},
		{"shim", "TaskStart"},
		{"shim", "GuestKernelBoot"},
		{"shim", "GuestKernelInit"},
		{"shim", "VsockReady"},
		{"agent", "StartContainer"},
	} {
		if !validOperation(metric.component, metric.operation) {
			t.Errorf("%s/%s is not accepted", metric.component, metric.operation)
		}
	}
}

func TestEventInflightTracksTimerLifecycle(t *testing.T) {
	m := New(prometheus.NewRegistry())
	m.acceptEvent([]byte(`{"version":1,"event_type":"start","component":"shim","operation":"VmmReady"}`))
	m.acceptEvent([]byte(`{"version":1,"event_type":"finish","component":"shim","operation":"VmmReady","result":"ok","duration_seconds":0.01}`))
	key := "shim\x00VmmReady"
	if got := m.eventInflight[key]; got != 0 {
		t.Fatalf("event inflight=%d, want 0", got)
	}
}

func TestEventFinishWithoutStartDoesNotUnderflow(t *testing.T) {
	m := New(prometheus.NewRegistry())
	m.acceptEvent([]byte(`{"version":1,"event_type":"finish","component":"shim","operation":"VmmReady","result":"ok","duration_seconds":0.01}`))
	if got := m.eventInflight["shim\x00VmmReady"]; got != 0 {
		t.Fatalf("event inflight=%d, want 0", got)
	}
}
