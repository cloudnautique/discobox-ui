package bridge

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func TestPoolProxyPatchIsScopedAndNullResetsWithoutRestart(t *testing.T) {
	b, _ := New("http://fixture")
	req := wire.Request{Operation: "updatePoolProxy", ProjectID: "p", PoolID: "pool", Payload: []byte(`{"proxy":null,"expectedProxy":{"mode":"direct"}}`)}
	if _, err := b.execute(t.Context(), req); err == nil {
		t.Fatal("unauthorized network update")
	}
	b.allowManage = true
	changed := false
	writes := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/projects/p/pools/pool" {
			t.Fatalf("retargeted or restarted pool %s", r.URL)
		}
		body := `{"proxy":{"mode":"direct"}}`
		if changed {
			body = `{"proxy":{"mode":"inherit"}}`
		}
		if r.Method != "GET" {
			writes++
			if r.Method != "PATCH" {
				t.Fatalf("unexpected method %s", r.Method)
			}
			data, _ := io.ReadAll(r.Body)
			var fields map[string]json.RawMessage
			_ = json.Unmarshal(data, &fields)
			if len(fields) != 1 || string(fields["proxy"]) != "null" {
				t.Fatalf("unrelated pool mutation %s", data)
			}
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	changed = true
	if _, err := b.execute(t.Context(), req); err == nil || writes != 0 {
		t.Fatal("stale network form saved")
	}
	changed = false
	if _, err := b.execute(t.Context(), req); err != nil || writes != 1 {
		t.Fatalf("reset writes=%d err=%v", writes, err)
	}
}

func TestConfiguredDefaultDoesNotOverrideExplicitEndpoints(t *testing.T) {
	t.Setenv("DISCOBOX_SERVER_ADDRESS", "http://127.0.0.1:12345")
	b, err := New("unix://")
	if err != nil || b.base != "http://127.0.0.1:12345" {
		t.Fatalf("default %v %v", b, err)
	}
	b, err = New("https://fixture.invalid")
	if err != nil || b.base != "https://fixture.invalid" {
		t.Fatalf("explicit %v %v", b, err)
	}
	t.Setenv("DISCOBOX_SERVER_ADDRESS", "unix://")
	if _, err = New("unix://"); err == nil {
		t.Fatal("recursive default allowed")
	}
	// A pinned IPC endpoint is independent of the broken shorthand default.
	if _, err = New("unix:///tmp/fixture%20socket.sock"); err != nil {
		t.Fatal(err)
	}
}
