// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package cubebox

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/urfave/cli/v2"

	"github.com/tencentcloud/CubeSandbox/Cubelet/api/services/cubebox/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/api/services/errorcode/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/cmd/cubecli/commands"
)

var DebugSnapshotRuntime = &cli.Command{
	Name:  "debug-snapshot-runtime",
	Usage: "DEBUG ONLY: export VM state and memory from a running sandbox",
	Flags: []cli.Flag{
		&cli.StringFlag{Name: "sandbox-id", Required: true},
		&cli.StringFlag{Name: "staging-dir", Required: true},
		&cli.BoolFlag{Name: "stop-after-snapshot"},
		&cli.BoolFlag{Name: "json"},
	},
	Action: debugSnapshotRuntimeAction,
}

func debugSnapshotRuntimeAction(cliCtx *cli.Context) error {
	conn, grpcCtx, cancel, err := commands.NewGrpcConn(cliCtx)
	if err != nil {
		return err
	}
	defer conn.Close()
	defer cancel()
	grpcCtx, grpcCancel := context.WithTimeout(grpcCtx, cliCtx.Duration("timeout"))
	defer grpcCancel()
	resp, err := cubebox.NewCubeboxMgrClient(conn).SnapshotRuntime(grpcCtx, &cubebox.SnapshotRuntimeRequest{
		RequestID:         uuid.NewString(),
		SandboxID:         cliCtx.String("sandbox-id"),
		StagingDir:        cliCtx.String("staging-dir"),
		StopAfterSnapshot: cliCtx.Bool("stop-after-snapshot"),
	})
	if err != nil {
		return err
	}
	if cliCtx.Bool("json") {
		data, marshalErr := json.MarshalIndent(resp, "", "  ")
		if marshalErr != nil {
			return marshalErr
		}
		fmt.Println(string(data))
	}
	if resp.GetRet() == nil || resp.GetRet().GetRetCode() != errorcode.ErrorCode_Success {
		return fmt.Errorf("SnapshotRuntime failed: %s", resp.GetRet().GetRetMsg())
	}
	if !cliCtx.Bool("json") {
		fmt.Printf("snapshot runtime sandbox=%s staging_dir=%s completed at %s\n", resp.GetSandboxID(), resp.GetStagingDir(), time.Now().Format(time.RFC3339))
	}
	return nil
}
