package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/discobox-ai/discobox/cli/internal/portforward"
)

type reportedPort struct {
	Port        int      `json:"port"`
	Protocol    string   `json:"protocol"`
	Addresses   []string `json:"addresses"`
	ServiceID   string   `json:"serviceId"`
	ServiceName string   `json:"serviceName"`
}
type forwardedPort struct {
	Port        int    `json:"port"`
	Local       int    `json:"local"`
	Protocol    string `json:"protocol"`
	ServiceID   string `json:"serviceId"`
	ServiceName string `json:"serviceName"`
}
type forwardSnapshot struct {
	Ports []forwardedPort `json:"ports"`
	Error string          `json:"error,omitempty"`
}

func reportedTargets(data []byte) ([]portforward.Target, error) {
	var box struct {
		Runtime struct {
			RuntimeState string `json:"runtimeState"`
			DisplayState string `json:"displayState"`
			AgentStatus  struct {
				Ports []reportedPort `json:"ports"`
			} `json:"agentStatus"`
		} `json:"runtime"`
	}
	if err := json.Unmarshal(data, &box); err != nil {
		return nil, err
	}
	if box.Runtime.RuntimeState != "running" || (box.Runtime.DisplayState != "" && box.Runtime.DisplayState != "running") {
		return nil, errors.New("Box is not running. Start it to open its services.")
	}
	targets := make([]portforward.Target, 0)
	for _, p := range box.Runtime.AgentStatus.Ports {
		if p.Port < 1 || p.Port > 65535 {
			continue
		}
		network := portforward.TCP
		if p.Protocol == "udp" {
			network = portforward.UDP
		}
		targets = append(targets, portforward.Target{Port: p.Port, Network: network, Host: dialHostForPort(p.Addresses, network), Protocol: p.Protocol, ServiceID: p.ServiceID, ServiceName: p.ServiceName})
	}
	return targets, nil
}

type runningPortDialer struct {
	b      *bridge
	req    request
	tunnel *sandboxPortDialer
}

func (d runningPortDialer) DialPort(ctx context.Context, target portforward.Target) (net.Conn, error) {
	check, cancel := context.WithTimeout(ctx, 10*time.Second)
	err := d.b.requireRunningBox(check, d.req)
	cancel()
	if err != nil {
		return nil, err
	}
	return d.tunnel.DialPort(ctx, target)
}

func runForward(endpoint string, req request, input io.Reader, output io.Writer) error {
	if err := validID(req.ProjectID); err != nil {
		return err
	}
	if err := validID(req.SandboxID); err != nil {
		return err
	}
	b, err := newBridge(endpoint, false)
	if err != nil {
		return err
	}
	defer b.client.CloseIdleConnections()
	b.client.Timeout = 0 // individual reads and handshakes carry deadlines
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	// The GUI keeps stdin open. Its exit closes the pipe, even without SIGTERM.
	go func() { _, _ = io.Copy(io.Discard, input); cancel() }()
	events := make(chan string, 8)
	forward := portforward.New(ctx, portforward.Options{
		Dialer: runningPortDialer{b: b, req: req, tunnel: &sandboxPortDialer{baseURL: b.base, client: b.client, projectID: req.ProjectID, sandboxID: req.SandboxID}},
		Observe: func(event portforward.Event) {
			if event.Kind == portforward.BindFailed || event.Kind == portforward.DialFailed {
				select {
				case events <- event.String():
				default:
				}
			}
		},
	})
	defer forward.Close()
	encoder := json.NewEncoder(output)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	var lastError string
	for {
		read, done := context.WithTimeout(ctx, 10*time.Second)
		res, err := b.call(read, "GET", "/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID, nil)
		done()
		var targets []portforward.Target
		if err == nil && res.Status != 200 {
			err = fmt.Errorf("Port discovery failed (HTTP %d)", res.Status)
		}
		if err == nil {
			targets, err = reportedTargets(res.Body)
		}
		if err != nil {
			lastError = err.Error()
		}
		forward.Set(targets) // failed/stopped listings deactivate old routes
		snapshot := forwardSnapshot{Ports: []forwardedPort{}, Error: lastError}
		for _, binding := range forward.Bindings() {
			if binding.Active {
				t := binding.Target
				snapshot.Ports = append(snapshot.Ports, forwardedPort{Port: t.Port, Local: binding.Local, Protocol: t.Protocol, ServiceID: t.ServiceID, ServiceName: t.ServiceName})
			}
		}
		if err := encoder.Encode(snapshot); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case lastError = <-events:
		case <-ticker.C:
			lastError = ""
		}
	}
}
