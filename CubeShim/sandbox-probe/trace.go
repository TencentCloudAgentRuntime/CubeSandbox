// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const defaultTracePath = "/run/cube-s0/trace.jsonl"

var traceMu sync.Mutex

func tracePath() string {
	if path := os.Getenv("CUBE_S0_TRACE_PATH"); path != "" {
		return path
	}
	return defaultTracePath
}

func record(event string, fields map[string]any) {
	entry := map[string]any{
		"time":  time.Now().UTC().Format(time.RFC3339Nano),
		"event": event,
		"pid":   os.Getpid(),
	}
	for key, value := range fields {
		entry[key] = value
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}

	traceMu.Lock()
	defer traceMu.Unlock()
	path := tracePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = file.Write(append(data, '\n'))
}

func recordResult(event string, fields map[string]any, err error) {
	if err != nil {
		fields["error"] = err.Error()
	} else {
		fields["result"] = "ok"
	}
	record(event, fields)
}
