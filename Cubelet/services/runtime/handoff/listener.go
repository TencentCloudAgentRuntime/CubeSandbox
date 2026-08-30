// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package handoff

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
)

// Listener owns the Kubernetes RuntimeResource FD side channel.
type Listener struct {
	path      string
	listener  *net.UnixListener
	registry  *Registry
	authorize PeerAuthorizer
	closed    chan struct{}
	once      sync.Once
}

func Listen(path string, mode os.FileMode, registry *Registry, authorize PeerAuthorizer) (*Listener, error) {
	if path == "" || registry == nil || authorize == nil {
		return nil, errors.New("fd handoff listener path/registry/authorizer is nil")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if err := removeStaleSocket(path); err != nil {
		return nil, err
	}
	address, err := net.ResolveUnixAddr("unix", path)
	if err != nil {
		return nil, err
	}
	unixListener, err := net.ListenUnix("unix", address)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, mode); err != nil {
		unixListener.Close()
		return nil, err
	}
	listener := &Listener{path: path, listener: unixListener, registry: registry, authorize: authorize, closed: make(chan struct{})}
	go listener.serve()
	return listener, nil
}

func (l *Listener) serve() {
	defer close(l.closed)
	for {
		conn, err := l.listener.AcceptUnix()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			_ = ServeConn(conn, l.registry, l.authorize)
		}()
	}
}

func (l *Listener) Close() error {
	if l == nil {
		return nil
	}
	var err error
	l.once.Do(func() {
		err = l.listener.Close()
		<-l.closed
		if removeErr := os.Remove(l.path); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) && err == nil {
			err = removeErr
		}
	})
	return err
}

func removeStaleSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("fd handoff endpoint exists and is not a socket")
	}
	conn, dialErr := net.Dial("unix", path)
	if dialErr == nil {
		conn.Close()
		return errors.New("fd handoff endpoint is already serving")
	}
	return os.Remove(path)
}
