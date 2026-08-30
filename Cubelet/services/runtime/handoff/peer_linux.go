// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package handoff

import (
	"fmt"
	"net"
	"syscall"
)

// AuthorizePeerIDs accepts a peer when both UID and GID match an allowed pair.
// Socket filesystem ACLs remain the first gate; SO_PEERCRED binds the process.
func AuthorizePeerIDs(allowed ...syscall.Ucred) PeerAuthorizer {
	pairs := make(map[[2]uint32]struct{}, len(allowed))
	for _, credential := range allowed {
		pairs[[2]uint32{credential.Uid, credential.Gid}] = struct{}{}
	}
	return func(conn *net.UnixConn) error {
		raw, err := conn.SyscallConn()
		if err != nil {
			return err
		}
		var (
			peer    *syscall.Ucred
			peerErr error
		)
		if err := raw.Control(func(fd uintptr) {
			peer, peerErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		}); err != nil {
			return err
		}
		if peerErr != nil {
			return peerErr
		}
		if peer == nil {
			return fmt.Errorf("SO_PEERCRED returned no credentials")
		}
		if _, ok := pairs[[2]uint32{peer.Uid, peer.Gid}]; !ok {
			return fmt.Errorf("unix peer uid=%d gid=%d is not allowed", peer.Uid, peer.Gid)
		}
		return nil
	}
}
