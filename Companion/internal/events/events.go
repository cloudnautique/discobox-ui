// Package events translates one project event subscription to bounded JSON lines.
// The parent owns replay and retries. This mode only reads the server database.
package events

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
)

const maxFrame = 128 << 10

type frame struct {
	Version int             `json:"version"`
	Kind    string          `json:"kind"`
	ID      *int64          `json:"id,omitempty"`
	Type    string          `json:"type,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
	Retry   int64           `json:"retry,omitempty"`
}

// Run returns to main on owner EOF or a stuck stdout write, even if the OS
// pipe is full. Returning from this dedicated mode releases its descriptors.
func Run(endpoint, project string, cursor int64, owner io.Reader, out io.Writer) error {
	if err := bridge.ValidID(project); err != nil {
		return err
	}
	b, err := bridge.New(endpoint)
	if err != nil {
		return err
	}
	client := b.HTTPClient()
	client.Timeout = 0 // The transport still bounds response-header negotiation.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, owner); cancel() }()
	idle := time.AfterFunc(50*time.Second, cancel) // Server pings at least every 15 seconds.
	defer idle.Stop()
	done := make(chan error, 1)
	go func() {
		enc := json.NewEncoder(out)
		send := func(f frame) error {
			idle.Reset(50 * time.Second)
			watchdog := time.AfterFunc(5*time.Second, cancel)
			defer watchdog.Stop()
			f.Version = 1
			return enc.Encode(f)
		}
		err := subscribe(ctx, client, b.BaseURL()+"/api/projects/"+project+"/events", cursor, send)
		if err != nil && ctx.Err() == nil {
			_ = send(frame{Kind: "error"})
		}
		done <- err
	}()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func subscribe(ctx context.Context, client *http.Client, url string, cursor int64, send func(frame) error) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	if cursor >= 0 {
		req.Header.Set("Last-Event-ID", strconv.FormatInt(cursor, 10))
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode == 404 || res.StatusCode == 405 {
		return send(frame{Kind: "unsupported"})
	}
	if res.StatusCode != 200 {
		return fmt.Errorf("project event stream returned HTTP %d", res.StatusCode)
	}
	t, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	if t != "text/event-stream" {
		return errors.New("invalid project event content type")
	}
	return read(res.Body, send)
}

// Bound the complete block as well as each line (multiple data fields form
// one event). Comments and retry-only blocks carry no cursor.
func read(r io.Reader, send func(frame) error) error {
	scan := bufio.NewScanner(r)
	scan.Buffer(make([]byte, 4096), maxFrame)
	var f frame
	var data strings.Builder
	size := 0
	for scan.Scan() {
		line := scan.Text()
		if line == "" {
			switch {
			case f.Type == "reset":
				f.Kind = "reset"
			case f.Type != "" || data.Len() != 0:
				if f.ID == nil || !json.Valid([]byte(data.String())) {
					return errors.New("invalid project event")
				}
				f.Kind, f.Data = "event", json.RawMessage(data.String())
			case f.ID != nil:
				f.Kind = "checkpoint"
			}
			if f.Kind != "" {
				if err := send(f); err != nil {
					return err
				}
			}
			f, size = frame{}, 0
			data.Reset()
			continue
		}
		size += len(line) + 1
		if size > maxFrame {
			return errors.New("project event too large")
		}
		field, value, _ := strings.Cut(line, ":")
		value = strings.TrimPrefix(value, " ")
		switch field {
		case "":
			f.Kind = "heartbeat"
		case "retry":
			n, err := strconv.ParseInt(value, 10, 64)
			if err == nil && n > 0 {
				f.Kind, f.Retry = "retry", n
			}
		case "id":
			id, err := strconv.ParseInt(value, 10, 64)
			if err != nil || id < 0 {
				return errors.New("invalid project event cursor")
			}
			f.ID = &id
		case "event":
			f.Type = value
		case "data":
			if data.Len() > 0 {
				data.WriteByte('\n')
			}
			data.WriteString(value)
		}
	}
	if err := scan.Err(); err != nil {
		return err
	}
	return io.ErrUnexpectedEOF
}
