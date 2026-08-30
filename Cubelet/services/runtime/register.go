// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package runtime owns only the direct RuntimeResource gRPC registration
// boundary. S1 supplies an implementation through explicit resource adapters.
package runtime

import (
	"errors"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"google.golang.org/grpc"
)

// Register binds RuntimeResource directly to the Cubelet gRPC server. It does
// not receive a containerd plugin InitContext and cannot resolve CRI services.
func Register(server grpc.ServiceRegistrar, implementation runtimev1.RuntimeResourceServer) error {
	if server == nil {
		return errors.New("runtime resource registrar is nil")
	}
	if implementation == nil {
		return errors.New("runtime resource implementation is nil")
	}
	runtimev1.RegisterRuntimeResourceServer(server, implementation)
	return nil
}
