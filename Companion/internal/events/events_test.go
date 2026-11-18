package events

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"testing/iotest"
	"time"
)

func TestFragmentedReplayAndResumeCursor(t *testing.T) {
	stream := "retry: 2000\r\n\r\n: ping\n\nevent: reset\ndata: {}\n\nid: 9\nevent: sandbox.updated\ndata: {\ndata: \"sandboxId\":\"s\"}\n\nid: 9\n\n"
	var got []frame
	err := read(iotest.OneByteReader(strings.NewReader(stream)), func(f frame) error { got = append(got, f); return nil })
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatal(err)
	}
	var kinds []string
	for _, f := range got {
		kinds = append(kinds, f.Kind)
	}
	if !reflect.DeepEqual(kinds, []string{"retry", "heartbeat", "reset", "event", "checkpoint"}) || got[0].Retry != 2000 || *got[4].ID != 9 {
		t.Fatal(got)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Last-Event-ID") != "9" || r.Header.Get("Accept") != "text/event-stream" {
			t.Error(r.Header)
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	err = subscribe(context.Background(), server.Client(), server.URL, 9, func(f frame) error {
		if f.Kind != "unsupported" {
			t.Error(f)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAggregateFrameLimit(t *testing.T) {
	for _, bad := range []string{strings.Repeat("a", maxFrame+1), strings.Repeat("data: abcd\n", maxFrame/10+1), "id: -1\n\n", "id: 2\nevent: sandbox.updated\ndata: nope\n\n"} {
		err := read(strings.NewReader(bad), func(frame) error { t.Fatal("accepted invalid frame"); return nil })
		if err == nil || errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatal(err)
		}
	}
}

type blockedWriter struct{ entered, release chan struct{} }

func (w blockedWriter) Write(p []byte) (int, error) {
	close(w.entered)
	<-w.release
	return 0, io.ErrClosedPipe
}

func TestBlockedDeliveryClosesTheAttachment(t *testing.T) {
	for _, ownerExits := range []bool{true, false} {
		t.Run(fmt.Sprintf("ownerExits=%t", ownerExits), func(t *testing.T) {
			closed := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/projects/demo/events" {
					t.Error(r.URL.Path)
				}
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, ": ping\n\n")
				w.(http.Flusher).Flush()
				<-r.Context().Done()
				close(closed)
			}))
			defer server.Close()
			r, w := io.Pipe()
			output := blockedWriter{make(chan struct{}), make(chan struct{})}
			defer close(output.release)
			defer w.Close()
			done := make(chan error, 1)
			go func() { done <- Run(server.URL, "demo", -1, r, output) }()
			select {
			case <-output.entered:
			case <-time.After(3 * time.Second):
				t.Fatal("no event")
			}
			if ownerExits {
				w.Close()
			}
			select {
			case <-done:
			case <-time.After(7 * time.Second):
				t.Fatal("blocked delivery kept the subscription alive")
			}
			select {
			case <-closed:
			case <-time.After(time.Second):
				t.Fatal("server still streaming")
			}
		})
	}
}
