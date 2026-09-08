package crimetrics

import "testing"

func TestValidOperationIncludesTaskLifecycle(t *testing.T) {
	for _, metric := range []struct{ component, operation string }{
		{"shim", "TaskCreate"},
		{"shim", "TaskStart"},
		{"agent", "StartContainer"},
	} {
		if !validOperation(metric.component, metric.operation) {
			t.Errorf("%s/%s is not accepted", metric.component, metric.operation)
		}
	}
}
