package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUploadFailureExplainsActualResponseWithoutRetry(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"old agent", 404, "404 page not found\n", "does not support the Files API"},
		{"missing directory", 404, `{"error":"parent directory not found"}`, "parent directory not found"},
		{"existing", 412, `{"error":"file already exists"}`, "confirm replacement"},
		{"permission", 403, `{"error":"permission denied"}`, "permission denied"},
		{"disk full", 507, `{"error":"no space left on device"}`, "no space left on device"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			local := filepath.Join(t.TempDir(), "Screenshot.png")
			if err := os.WriteFile(local, []byte("image"), 0600); err != nil {
				t.Fatal(err)
			}
			b, _ := newBridge("http://fixture", false)
			b.allowManage = true
			writes := 0
			remote := "/workspace/source/Screenshot 2026-11-02 at 1.04.14\u202fPM.png"
			b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
				if r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/sandboxes/b") {
					return reply(`{"runtime":{"runtimeState":"running"}}`), nil
				}
				writes++
				if r.Method != "PUT" || r.URL.Query().Get("path") != remote || r.URL.Query().Get("ifExists") != "fail" {
					t.Fatalf("changed upload semantics: %v", r)
				}
				result := reply(tc.body)
				result.StatusCode = tc.status
				return result, nil
			})
			_, err := b.execute(t.Context(), request{Operation: "upload", ProjectID: "p", SandboxID: "b", RemotePath: remote, LocalPath: local})
			if writes != 1 || err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("writes=%d error=%v", writes, err)
			}
			if tc.status != 412 && strings.Contains(err.Error(), "replacement") {
				t.Fatalf("misleading conflict: %v", err)
			}
		})
	}
}

func TestReplacementStopsWhenStatRouteIsMissing(t *testing.T) {
	local := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(local, []byte("image"), 0600); err != nil {
		t.Fatal(err)
	}
	b, _ := newBridge("http://fixture", false)
	calls := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || !strings.HasSuffix(r.URL.Path, "/stat") {
			t.Fatalf("wrote after missing stat API: %v", r)
		}
		result := reply("404 page not found\n")
		result.StatusCode = 404
		return result, nil
	})
	err := b.uploadTree(t.Context(), "/files", local, "/target", true, &transferProgress{}, 0)
	if calls != 1 || err == nil || !strings.Contains(err.Error(), "Files API") {
		t.Fatalf("calls=%d error=%v", calls, err)
	}
}
