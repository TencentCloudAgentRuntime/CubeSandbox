// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"bufio"
	"os/exec"
	"strings"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"google.golang.org/grpc"
)

type contractServer struct {
	runtimev1.UnimplementedRuntimeResourceServer
}

func TestRegisterUsesDirectGRPCService(t *testing.T) {
	server := grpc.NewServer()
	if err := Register(server, &contractServer{}); err != nil {
		t.Fatal(err)
	}
	info := server.GetServiceInfo()
	const serviceName = "cubelet.services.runtime.v1.RuntimeResource"
	if _, ok := info[serviceName]; !ok {
		t.Fatalf("registered services=%v, missing %s", info, serviceName)
	}
}

func TestRuntimeResourceImportGraphExcludesContainerdAndLegacyServices(t *testing.T) {
	command := exec.Command("go", "list", "-deps", "./services/runtime/...")
	command.Dir = "../.."
	output, err := command.Output()
	if err != nil {
		t.Fatalf("go list runtime dependencies: %v", err)
	}
	forbiddenPrefixes := []string{
		"github.com/containerd/containerd",
		"github.com/tencentcloud/CubeSandbox/Cubelet/services/cubebox",
		"github.com/tencentcloud/CubeSandbox/Cubelet/services/images",
		"github.com/tencentcloud/CubeSandbox/Cubelet/services/nbi",
		"github.com/tencentcloud/CubeSandbox/Cubelet/services/server",
		"github.com/tencentcloud/CubeSandbox/Cubelet/services/snapshot",
	}
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		dependency := scanner.Text()
		for _, prefix := range forbiddenPrefixes {
			if dependency == prefix || strings.HasPrefix(dependency, prefix+"/") {
				t.Fatalf("RuntimeResource dependency graph contains forbidden package %s", dependency)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
}
