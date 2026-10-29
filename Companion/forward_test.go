package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/cli/internal/portforward"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
)

func TestReportedTargetsKeepDesktopMultiplePortsAndBindAddresses(t *testing.T) {
	targets, err := reportedTargets([]byte(`{"runtime":{"runtimeState":"running","agentStatus":{"ports":[{"port":7100,"protocol":"http","serviceId":"ai.discobox.desktop","serviceName":"Desktop","addresses":["::1"]},{"port":5432,"protocol":"tcp","addresses":["10.0.0.2"]},{"port":53,"protocol":"udp","addresses":["::1"]},{"port":0},{"port":65536}]}}}`))
	if err != nil || len(targets) != 3 {
		t.Fatalf("targets=%+v err=%v", targets, err)
	}
	if targets[0].Host != "localhost" || targets[0].ServiceID != "ai.discobox.desktop" || targets[1].Host != "10.0.0.2" || targets[2].Host != "::1" || targets[2].Network != portforward.UDP {
		t.Fatalf("wrong targets %+v", targets)
	}
	if _, err := reportedTargets([]byte(`{"runtime":{"runtimeState":"stopped"}}`)); err == nil {
		t.Fatal("accepted stopped box")
	}
}

func TestForwardBrowserTrafficUsesLocalBindingAndClosesOnParentEOF(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	port := occupied.Addr().(*net.TCPAddr).Port
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("unexpected mutation %s", r.Method)
			http.Error(w, "mutation", 500)
			return
		}
		if r.URL.Path == "/projects/p/sandboxes/s" {
			fmt.Fprintf(w, `{"runtime":{"runtimeState":"running","agentStatus":{"ports":[{"port":%d,"protocol":"http","serviceId":"ai.discobox.desktop","serviceName":"Desktop"}]}}}`, port)
			return
		}
		if r.URL.Path != "/api/projects/p/sandboxes/s/tcp/attach" {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("port") != strconv.Itoa(port) || r.URL.Query().Get("host") != "localhost" {
			t.Errorf("tunnel must dial the box port, not the remapped local port: %s", r.URL.RawQuery)
			http.Error(w, "wrong target", 400)
			return
		}
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer ws.CloseNow()
		stream := websocket.NetConn(r.Context(), ws, websocket.MessageBinary)
		var request strings.Builder
		for !strings.Contains(request.String(), "\r\n\r\n") {
			f, err := frame.Read(stream)
			if err != nil {
				return
			}
			if f.Type == frame.Input {
				request.Write(f.Payload)
			}
		}
		_ = frame.Write(stream, frame.Stdout, []byte("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\ndesktop"))
		_ = frame.Write(stream, frame.CloseOutput, nil)
		for {
			if _, err := frame.Read(stream); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	input, parent := io.Pipe()
	output, writer := io.Pipe()
	defer output.Close()
	defer parent.Close()
	finished := make(chan error, 1)
	go func() {
		finished <- runForward(server.URL, request{ProjectID: "p", SandboxID: "s"}, input, writer)
		writer.Close()
	}()
	var snapshot forwardSnapshot
	if err := json.NewDecoder(output).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	// Continue draining reports so the fixture's writer cannot block shutdown.
	go io.Copy(io.Discard, output)
	if len(snapshot.Ports) != 1 || snapshot.Ports[0].Local == port {
		t.Fatalf("collision was not remapped: %+v", snapshot)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/", snapshot.Ports[0].Local))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != "desktop" {
		t.Fatalf("body=%q", body)
	}
	parent.Close()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("forwarder did not exit on parent EOF")
	}
	connection, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", snapshot.Ports[0].Local), time.Second)
	if err == nil {
		connection.Close()
		t.Fatal("listener survived shutdown")
	}
}

func TestTunnelCarriesTCPHalfCloseAndUDPDatagrams(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer ws.CloseNow()
		stream := websocket.NetConn(r.Context(), ws, websocket.MessageBinary)
		for {
			f, err := frame.Read(stream)
			if err != nil {
				return
			}
			switch f.Type {
			case frame.Input:
				if frame.Write(stream, frame.Stdout, f.Payload) != nil {
					return
				}
			case frame.CloseInput:
				_ = frame.Write(stream, frame.CloseOutput, nil)
			}
		}
	}))
	defer server.Close()
	for _, network := range []portforward.Network{portforward.TCP, portforward.UDP} {
		dialer := &sandboxPortDialer{baseURL: server.URL, client: server.Client(), projectID: "p", sandboxID: "s"}
		conn, err := dialer.DialPort(t.Context(), portforward.Target{Network: network, Host: "localhost", Port: 8080})
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		for _, message := range []string{"first", "second"} {
			if _, err := conn.Write([]byte(message)); err != nil {
				t.Fatal(err)
			}
			buffer := make([]byte, 128)
			n, err := conn.Read(buffer)
			if err != nil || string(buffer[:n]) != message {
				t.Fatalf("echo: %q %v", buffer[:n], err)
			}
		}
		if err := conn.(*tunnelConn).CloseWrite(); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Read(make([]byte, 16)); err != io.EOF {
			t.Fatalf("half-close: %v", err)
		}
		conn.Close()
	}
}
