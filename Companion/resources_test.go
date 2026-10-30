package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	api "github.com/discobox-ai/discobox/api/gen"
)

func TestPoolResourcesOnlyReadsStoredReportsAndPlacement(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	var paths []string
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Fatal("resource read mutated server")
		}
		paths = append(paths, r.URL.Path)
		if r.URL.Path == "/projects/p/pools" {
			return reply(`{"pools":[{"id":"pool-a","name":"Development","resources":{"futureField":42,"storage":{"walk":{"cacheBytes":999}}}}]}`), nil
		}
		if r.URL.Path != "/projects/p" {
			t.Fatal(r.URL.Path)
		}
		return reply(`{"defaultPoolId":"pool-a"}`), nil
	})
	result, err := b.execute(t.Context(), request{Operation: "poolResources", ProjectID: "p"})
	if err != nil || len(paths) != 2 || !strings.Contains(string(result.Body), `"futureField":42`) || !strings.Contains(string(result.Body), `"defaultPoolId":"pool-a"`) {
		t.Fatalf("%v %v %s", paths, err, result.Body)
	}
	paths = nil
	if _, err := b.execute(t.Context(), request{Operation: "poolResources", ProjectID: "../other"}); err == nil || len(paths) != 0 {
		t.Fatal("invalid project reached transport")
	}
}

func TestPoolCacheClearIsExplicitScopedAndNotRetried(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = authorized
		calls := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "POST" || r.URL.Path != "/projects/p/pools/pool-a/clear-cache" {
				t.Fatalf("%s %s", r.Method, r.URL.Path)
			}
			return nil, errors.New("response lost after possible commit")
		})
		_, err := b.execute(t.Context(), request{Operation: "clearPoolCache", ProjectID: "p", PoolID: "pool-a"})
		want := 0
		if authorized {
			want = 1
		}
		if err == nil || calls != want {
			t.Fatalf("authorized=%v calls=%d err=%v", authorized, calls, err)
		}
		for _, id := range []string{"", "../other", "a/b"} {
			if _, err := b.execute(t.Context(), request{Operation: "clearPoolCache", ProjectID: "p", PoolID: id}); err == nil || calls != want {
				t.Fatal("invalid pool reached transport")
			}
		}
	}
}

func TestDataDiskPreflightDistinguishesMissingStaleAndFull(t *testing.T) {
	now := time.Now().UTC()
	for _, tc := range []struct {
		name string
		age  time.Duration
		fs   string
		want bool
	}{
		{"full", 0, `{"totalBytes":100,"usedBytes":97,"freeBytes":0}`, true},
		{"reserved blocks", time.Second, `{"totalBytes":100,"usedBytes":80,"freeBytes":0}`, true},
		{"available", 0, `{"totalBytes":100,"freeBytes":1}`, false},
		{"missing free", 0, `{"totalBytes":100}`, false},
		{"unmeasured zeroes", 0, `{"totalBytes":0,"freeBytes":0}`, false},
		{"stale", 91 * time.Second, `{"totalBytes":100,"freeBytes":0}`, false},
		{"future", -time.Minute, `{"totalBytes":100,"freeBytes":0}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := json.RawMessage(`{"reportedAt":"` + now.Add(-tc.age).Format(time.RFC3339Nano) + `","storage":{"filesystem":` + tc.fs + `,"walk":{"cacheBytes":999999999999}}}`)
			if got := reportedDataDiskFull(raw, now); got != tc.want {
				t.Fatalf("got %v want %v", got, tc.want)
			}
		})
	}
	for _, raw := range []string{`{}`, `null`, `{"reportedAt":"invalid"}`, `{"storage":null}`} {
		if reportedDataDiskFull(json.RawMessage(raw), now) {
			t.Fatal("unknown telemetry blocked creation")
		}
	}
}

func TestCreationUsesCheckedPoolAndRejectsFreshFullDataDisk(t *testing.T) {
	t.Setenv("DISCOBOX_HOST_ID", "fixture-host")
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	for _, full := range []bool{false, true} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		creates := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			switch r.URL.Path {
			case "/projects/p/harness-configs/h":
				return reply(`{"configured":true}`), nil
			case "/projects/p":
				return reply(`{"defaultPoolId":"different-pool"}`), nil
			case "/projects/p/pools/checked-pool":
				free := 50
				if full {
					free = 0
				}
				raw, _ := json.Marshal(map[string]any{"platform": "linux/arm64", "schedulable": true, "resources": map[string]any{"reportedAt": time.Now().UTC().Format(time.RFC3339Nano), "storage": map[string]any{"filesystem": map[string]any{"totalBytes": 100, "freeBytes": free}}}})
				return reply(string(raw)), nil
			case "/projects/p/sandboxes":
				creates++
				if r.Method != "POST" {
					t.Fatal(r.Method)
				}
				var body struct {
					PoolID string `json:"poolId"`
				}
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.PoolID != "checked-pool" {
					t.Fatalf("placement changed: %+v %v", body, err)
				}
				box := api.Sandbox{ID: "new-box", ProjectId: "p", DisplayName: "New box", CreatedAt: time.Now(), UpdatedAt: time.Now(), Runtime: api.SandboxRuntime{State: api.SandboxRuntimeStateReady, DesiredState: api.SandboxRuntimeDesiredStatePresent}}
				data, _ := json.Marshal(&box)
				return &http.Response{StatusCode: 202, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
			default:
				t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
				return nil, nil
			}
		})
		_, err := b.createBox(context.Background(), request{ProjectID: "p", HarnessID: "h", PoolID: "checked-pool"})
		if full && (err == nil || creates != 0) || !full && (err != nil || creates != 1) {
			t.Fatalf("full=%v creates=%d err=%v", full, creates, err)
		}
	}
}
