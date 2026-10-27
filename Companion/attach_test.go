package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/host"
)

func TestAttachStreamReconnectAndDetach(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	applied := make(chan frame.Frame, 8)
	accepted := make(chan net.Conn, 4)
	hostDone := make(chan struct{})
	defer close(hostDone)
	var stream *host.Stream
	stream = host.New(host.Options{Done: hostDone, OnFrame: func(f frame.Frame) error {
		applied <- f
		if f.Type == frame.Input {
			stream.Broadcast(frame.Stdout, append([]byte("echo:"), f.Payload...))
		}
		return nil
	}})
	var count atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("unexpected mutation %s %s", r.Method, r.URL)
			http.Error(w, "no", 405)
			return
		}
		switch r.URL.Path {
		case "/projects/p/sandboxes/b":
			io.WriteString(w, `{"runtime":{"runtimeState":"running"}}`)
		case "/api/projects/p/sandboxes/b/execs/e":
			io.WriteString(w, `{"status":"running","tty":true}`)
		case "/api/projects/p/sandboxes/b/execs/e/attach":
			if r.URL.Query().Get("replay") != "true" {
				t.Error("missing replay")
			}
			ws, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			conn := websocket.NetConn(ctx, ws, websocket.MessageBinary)
			defer conn.Close()
			count.Add(1)
			accepted <- conn
			_ = stream.Attach(ctx, &attachFrames{Conn: conn}, host.AttachOptions{})
		default:
			t.Errorf("unexpected route %s", r.URL)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c, err := openAttach(ctx, server.URL, request{ProjectID: "p", SandboxID: "b", ExecID: "e"})
	if err != nil {
		t.Fatal(err)
	}
	inputR, inputW := io.Pipe()
	defer inputR.Close()
	defer inputW.Close()
	outputR, outputW := io.Pipe()
	defer outputR.Close()
	defer outputW.Close()
	sizes := make(chan frame.ResizePayload, 1)
	sizes <- frame.ResizePayload{Cols: 100, Rows: 30}
	done := make(chan error, 1)
	go func() { done <- pumpAttach(ctx, c, inputR, outputW, sizes) }()
	first := <-accepted
	select {
	case f := <-applied:
		if f.Type != frame.Resize {
			t.Fatalf("first frame: %d", f.Type)
		}
	case <-ctx.Done():
		t.Fatal("initial resize missing")
	}
	// One physical transport loss must preserve the logical input stream.
	first.Close()
	select {
	case <-accepted:
	case <-ctx.Done():
		t.Fatal("did not reconnect")
	}
	go func() { _, _ = inputW.Write([]byte("hello\x03")) }()
	data := make([]byte, len("echo:hello\x03"))
	if _, err := io.ReadFull(outputR, data); err != nil {
		t.Fatal(err)
	}
	if string(data) != "echo:hello\x03" {
		t.Fatalf("output %q", data)
	}
	inputW.Close()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("detach hung")
	}
	if count.Load() != 2 {
		t.Fatalf("attach count %d", count.Load())
	}
	// The initial resize was consumed and asserted above. A reconnect may
	// replay it, but its arrival before detach is not required for this check.
	inputs, resizes := 0, 1
	for len(applied) > 0 {
		f := <-applied
		switch f.Type {
		case frame.Input:
			inputs++
		case frame.Resize:
			resizes++
		default:
			t.Errorf("detach sent forbidden frame %d", f.Type)
		}
	}
	if inputs != 1 || resizes < 1 {
		t.Fatalf("inputs=%d resizes=%d", inputs, resizes)
	}
}

func TestAttachRefusesStoppedCachedAndVirtualTerminals(t *testing.T) {
	for _, state := range []string{"stopped", "cached", "exited", "primary"} {
		t.Run(state, func(t *testing.T) {
			var upgrades atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/attach") {
					upgrades.Add(1)
					http.Error(w, "unexpected", 500)
					return
				}
				if strings.HasPrefix(r.URL.Path, "/projects/") {
					if state == "stopped" {
						io.WriteString(w, `{"runtime":{"runtimeState":"stopped"}}`)
					} else {
						io.WriteString(w, `{"runtime":{"runtimeState":"running"}}`)
					}
				} else {
					if state == "cached" {
						io.WriteString(w, `{"status":"running","tty":true,"observedAt":"saved"}`)
					} else {
						io.WriteString(w, `{"status":"exited","tty":true}`)
					}
				}
			}))
			defer server.Close()
			id := "e"
			if state == "primary" {
				id = state
			}
			_, err := openAttach(t.Context(), server.URL, request{ProjectID: "p", SandboxID: "b", ExecID: id})
			if err == nil || upgrades.Load() != 0 {
				t.Fatalf("refusal: err=%v upgrades=%d", err, upgrades.Load())
			}
		})
	}
}

func TestResizeQueueKeepsFinalDimensions(t *testing.T) {
	sizes := make(chan frame.ResizePayload, 1)
	for cols := uint16(80); cols <= 160; cols++ {
		enqueueLatestSize(sizes, frame.ResizePayload{Cols: cols, Rows: 42})
	}
	got := <-sizes
	if got.Cols != 160 || got.Rows != 42 {
		t.Fatalf("final size lost: %+v", got)
	}
}

func TestAttachAppliesInitialSizeBeforeReplay(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	local, remote := net.Pipe()
	defer remote.Close()
	input, writer := io.Pipe()
	defer input.Close()
	defer writer.Close()
	sizes := make(chan frame.ResizePayload, 1)
	sizes <- frame.ResizePayload{Cols: 120, Rows: 40}
	done := make(chan error, 1)
	go func() { done <- pumpAttach(ctx, &attachFrames{Conn: local}, input, io.Discard, sizes) }()
	_ = remote.SetReadDeadline(time.Now().Add(2 * time.Second))
	first, err := frame.Read(remote)
	if err != nil {
		t.Fatal(err)
	}
	if first.Type != frame.Resize || string(first.Payload) != `{"cols":120,"rows":40}` {
		t.Fatalf("first frame: %+v", first)
	}
	second, err := frame.Read(remote)
	if err != nil {
		t.Fatal(err)
	}
	if second.Type != frame.Ready {
		t.Fatalf("second frame: %+v", second)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("pump did not stop")
	}
}
