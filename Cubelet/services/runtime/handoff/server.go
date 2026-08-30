// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package handoff

import (
	"fmt"
	"net"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
)

// PeerAuthorizer validates the Unix peer before any lease lookup or FD open.
// S1 configures it with the CubeShim service account UID/GID.
type PeerAuthorizer func(*net.UnixConn) error

const DefaultIOTimeout = time.Second

// ServeConn handles exactly one request and response. The connection is not
// closed by this function so the listener owns connection lifecycle.
func ServeConn(conn *net.UnixConn, registry *Registry, authorize PeerAuthorizer) error {
	if conn == nil || registry == nil {
		return fmt.Errorf("fd handoff connection/registry is nil")
	}
	if err := conn.SetDeadline(time.Now().Add(DefaultIOTimeout)); err != nil {
		return err
	}
	if authorize == nil {
		return SendResponse(conn, &runtimev1.FDHandoffResponseV1{
			Code:    runtimev1.FDHandoffCode_FD_HANDOFF_CODE_UNAUTHORIZED,
			Message: "unix peer authorizer is required",
		}, nil)
	}
	if err := authorize(conn); err != nil {
		return SendResponse(conn, &runtimev1.FDHandoffResponseV1{
			Code:    runtimev1.FDHandoffCode_FD_HANDOFF_CODE_UNAUTHORIZED,
			Message: err.Error(),
		}, nil)
	}

	request, err := ReadRequest(conn)
	if err != nil {
		return SendResponse(conn, &runtimev1.FDHandoffResponseV1{
			Code:    runtimev1.FDHandoffCode_FD_HANDOFF_CODE_MALFORMED,
			Message: err.Error(),
		}, nil)
	}

	file, code, acquireErr := registry.Acquire(request)
	if file != nil {
		defer file.Close()
	}
	response := &runtimev1.FDHandoffResponseV1{Code: code}
	if acquireErr != nil {
		response.Message = acquireErr.Error()
	}
	return SendResponse(conn, response, file)
}
