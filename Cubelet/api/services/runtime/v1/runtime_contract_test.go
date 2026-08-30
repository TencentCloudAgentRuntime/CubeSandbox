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

func requireFields(t *testing.T, message protoreflect.MessageDescriptor, names ...protoreflect.Name) {
	t.Helper()
	for _, name := range names {
		if message.Fields().ByName(name) == nil {
			t.Fatalf("%s missing contract field %s", message.Name(), name)
		}
	}
}

func TestRuntimeResourceV1KeepsRetryIdentityAndFDsOutOfProtobuf(t *testing.T) {
	prepare := (&PrepareSandboxRequest{}).ProtoReflect().Descriptor()
	requireFields(t, prepare, "sandbox_id", "idempotency_key", "generation")

	attachment := (&NetworkAttachment{}).ProtoReflect().Descriptor()
	requireFields(t, attachment, "tap_name", "network_handle", "fd_handoff")
	for _, forbidden := range []protoreflect.Name{"fd", "fds", "tap_fd"} {
		if attachment.Fields().ByName(forbidden) != nil {
			t.Fatalf("NetworkAttachment must not encode %s; use SCM_RIGHTS side channel", forbidden)
		}
	}

	descriptor := (&FDHandoffDescriptor{}).ProtoReflect().Descriptor()
	requireFields(t, descriptor, "protocol_version", "endpoint", "token")

	handoffRequest := (&FDHandoffRequestV1{}).ProtoReflect().Descriptor()
	requireFields(t, handoffRequest,
		"protocol_version", "sandbox_id", "generation", "lease_id", "network_handle", "token")
	handoffResponse := (&FDHandoffResponseV1{}).ProtoReflect().Descriptor()
	requireFields(t, handoffResponse, "protocol_version", "code", "message", "fd_count")

	reconcile := (&ReconcileSandboxesRequest{}).ProtoReflect().Descriptor().Fields()
	if reconcile.ByName("delete_orphans") != nil || reconcile.ByName("force") != nil {
		t.Fatal("v1 ReconcileSandboxes must remain report-only")
	}
}
