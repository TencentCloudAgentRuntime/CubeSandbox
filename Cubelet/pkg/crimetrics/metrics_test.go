package crimetrics

import "testing"

func TestValidOperationAcceptsSandboxStartPaths(t *testing.T) {
	for _, operation := range []string{"TemplateDerivedSandbox", "ColdStartSandbox"} {
		if !validOperation("shim", operation) {
			t.Fatalf("sandbox start path operation %q is not accepted", operation)
		}
	}
}
