// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

package runtime

import (
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestRuntimeResourceV1MethodSetIsNodeResourcesOnly(t *testing.T) {
	service := File_api_services_runtime_v1_runtime_proto.Services().ByName("RuntimeResource")
	if service == nil {
		t.Fatal("RuntimeResource descriptor is missing")
	}

	want := []protoreflect.Name{
		"GetCapabilities",
		"PrepareSandbox",
		"ReleaseSandbox",
		"InspectSandbox",
		"ReconcileSandboxes",
	}
	if service.Methods().Len() != len(want) {
		t.Fatalf("RuntimeResource has %d methods, want %d", service.Methods().Len(), len(want))
	}
	for index, name := range want {
		if got := service.Methods().Get(index).Name(); got != name {
			t.Fatalf("method[%d]=%s, want %s", index, got, name)
		}
	}
}

func TestRuntimeResourceV1KeepsRetryIdentityAndFDsOutOfProtobuf(t *testing.T) {
	prepare := (&PrepareSandboxRequest{}).ProtoReflect().Descriptor().Fields()
	for _, name := range []protoreflect.Name{"sandbox_id", "idempotency_key", "generation"} {
		if prepare.ByName(name) == nil {
			t.Fatalf("PrepareSandboxRequest missing retry identity field %s", name)
		}
	}

	attachment := (&NetworkAttachment{}).ProtoReflect().Descriptor().Fields()
	if attachment.ByName("tap_name") == nil {
		t.Fatal("NetworkAttachment missing tap_name")
	}
	for _, forbidden := range []protoreflect.Name{"fd", "fds", "tap_fd"} {
		if attachment.ByName(forbidden) != nil {
			t.Fatalf("NetworkAttachment must not encode %s; use SCM_RIGHTS side channel", forbidden)
		}
	}

	reconcile := (&ReconcileSandboxesRequest{}).ProtoReflect().Descriptor().Fields()
	if reconcile.ByName("delete_orphans") != nil || reconcile.ByName("force") != nil {
		t.Fatal("v1 ReconcileSandboxes must remain report-only")
	}
}
