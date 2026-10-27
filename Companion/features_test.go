package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApprovalsRejectResolvedAndDoNotRetry(t *testing.T) {
	for _, status := range []string{"approved", "pending"} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		posts := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			if r.Method == "GET" {
				return reply(`{"id":"req","status":"` + status + `"}`), nil
			}
			posts++
			body, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(body), `"resolved"`) {
				t.Fatal("policy variables dropped")
			}
			return nil, errors.New("ambiguous socket failure")
		})
		_, err := b.execute(t.Context(), request{Operation: "answer", ProjectID: "p", Kind: "credential", RequestID: "req", Action: "approve", Payload: json.RawMessage(`{"policy":{"resolved":{"repo":"org/repo"}},"grantTTLSeconds":900}`)})
		if err == nil {
			t.Fatal("accepted failed request")
		}
		if status == "approved" && posts != 0 || status == "pending" && posts != 1 {
			t.Fatalf("posts: %d", posts)
		}
	}
}
func TestApprovalRefreshBindsTheRequestAndSecret(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "GET" {
			return reply(`{"id":"req","status":"pending","reason":"refresh","secretId":"sec"}`), nil
		}
		if r.URL.Path != "/projects/p/secrets/sec/refresh" {
			t.Fatal(r.URL.Path)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["requestId"] != "req" || body["via"] != "entered" {
			t.Fatal(body)
		}
		return reply(`{}`), nil
	})
	_, err := b.execute(t.Context(), request{Operation: "answer", ProjectID: "p", Kind: "credential", RequestID: "req", Action: "refresh", Payload: json.RawMessage(`{"value":"fixture","via":"entered","requestId":"wrong"}`)})
	if err != nil {
		t.Fatal(err)
	}
}
func fileFixture(t *testing.T, changed bool) *bridge {
	t.Helper()
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	stats := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/sandboxes/b") {
			return reply(`{"runtime":{"runtimeState":"running"}}`), nil
		}
		if strings.HasSuffix(r.URL.Path, "/stat") {
			stats++
			v := "1"
			if changed && stats > 1 {
				v = "2"
			}
			return reply(`{"path":"/workspace/a","name":"a","type":"file","size":5,"version":"` + v + `"}`), nil
		}
		if strings.HasSuffix(r.URL.Path, "/content") {
			return reply("hello"), nil
		}
		t.Fatal(r.URL)
		return nil, nil
	})
	return b
}
func TestDownloadPublishesOnlyStableFilesAndNeverOverwrites(t *testing.T) {
	for _, changed := range []bool{false, true} {
		dest := filepath.Join(t.TempDir(), "result")
		b := fileFixture(t, changed)
		_, err := b.execute(t.Context(), request{Operation: "download", ProjectID: "p", SandboxID: "b", RemotePath: "/workspace/a", LocalPath: dest})
		if changed {
			if err == nil {
				t.Fatal("accepted changed remote")
			}
			if _, e := os.Stat(dest); !os.IsNotExist(e) {
				t.Fatal("published partial file")
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			data, _ := os.ReadFile(dest)
			if string(data) != "hello" {
				t.Fatal(string(data))
			}
			_ = os.WriteFile(dest, []byte("keep"), 0600)
			_, err = b.execute(t.Context(), request{Operation: "download", ProjectID: "p", SandboxID: "b", RemotePath: "/workspace/a", LocalPath: dest})
			if err == nil {
				t.Fatal("overwrote existing path")
			}
			data, _ = os.ReadFile(dest)
			if string(data) != "keep" {
				t.Fatal("overwrote local data")
			}
		}
	}
}
func TestUploadUsesVersionAndStreamsRawContent(t *testing.T) {
	dir := t.TempDir()
	local := filepath.Join(dir, "file")
	_ = os.WriteFile(local, []byte("hello"), 0600)
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	writes := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/sandboxes/b") {
			return reply(`{"runtime":{"runtimeState":"running"}}`), nil
		}
		if strings.HasSuffix(r.URL.Path, "/stat") {
			return reply(`{"type":"file","version":"v1"}`), nil
		}
		writes++
		if r.Method != "PUT" || r.URL.Query().Get("ifVersion") != "v1" || r.Header.Get("Content-Type") != "application/octet-stream" {
			t.Fatal(r)
		}
		data, _ := io.ReadAll(r.Body)
		if string(data) != "hello" {
			t.Fatal("upload content changed")
		}
		return reply(`{}`), nil
	})
	_, err := b.execute(t.Context(), request{Operation: "upload", ProjectID: "p", SandboxID: "b", RemotePath: "/workspace/a", LocalPath: local, Action: "replace"})
	if err != nil || writes != 1 {
		t.Fatal(err, writes)
	}
	_ = os.Symlink(local, filepath.Join(dir, "link"))
	if err := b.uploadTree(context.Background(), "unused", filepath.Join(dir, "link"), "target", false, &transferProgress{}, 0); err == nil {
		t.Fatal("followed local symlink")
	}
}
func TestToolReattachesWithoutCreatingOrStarting(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Fatal("mutated existing session")
		}
		if strings.HasSuffix(r.URL.Path, "/execs") {
			return reply(`{"execs":[{"id":"diff","status":"running","metadata":{"tool":"ai.discobox.diff"}}]}`), nil
		}
		return reply(`{"runtime":{"runtimeState":"running"}}`), nil
	})
	result, err := b.execute(t.Context(), request{Operation: "openTool", ProjectID: "p", SandboxID: "b", Kind: "ai.discobox.diff"})
	if err != nil || !strings.Contains(string(result.Body), `"id":"diff"`) {
		t.Fatal(err, string(result.Body))
	}
}
func TestFileNamesCannotEscapeDestination(t *testing.T) {
	for _, name := range []string{"..", ".", "../secret", "a/b", "a\\b", "", "a\x00b"} {
		if safeChild(name) {
			t.Fatal("accepted", name)
		}
	}
}

func TestAuditForwardCursorIsScopedPerPool(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/audit/http"):
			if r.URL.Query().Get("after") != "pool-a:http_42" || r.URL.Query().Get("order") != "asc" {
				t.Error("missing forward cursor", r.URL)
			}
			return reply(`{"exchanges":[],"unavailablePools":[]}`), nil
		case strings.HasSuffix(r.URL.Path, "/credential-verdicts"):
			return reply(`{"credentialVerdicts":[]}`), nil
		case strings.HasSuffix(r.URL.Path, "/secret-refreshes"):
			return reply(`{"secretRefreshEvents":[]}`), nil
		case strings.HasSuffix(r.URL.Path, "/harness-hooks"):
			return reply(`{"hooks":[]}`), nil
		default:
			return reply(`{"events":[]}`), nil
		}
	})
	_, err := b.execute(t.Context(), request{Operation: "audit", ProjectID: "p", SandboxID: "b", Payload: json.RawMessage(`{"since":{"HTTP":"2026-10-26T10:00:00Z"},"after":{"pool-a":"http_42"}}`)})
	if err != nil {
		t.Fatal(err)
	}
}

func TestRecordingExportKeepsExactBytesAndDoesNotOverwrite(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	payload := strings.Repeat("\x00binary\xff", 150000)
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/api/projects/p/pools/pool/audit/http/http_42/response-body" || r.URL.Query().Get("sandboxId") != "b" {
			t.Fatal(r.URL)
		}
		return reply(payload), nil
	})
	dest := filepath.Join(t.TempDir(), "record.bin")
	req := request{Operation: "auditBody", ProjectID: "p", SandboxID: "b", Kind: "pool", RequestID: "http_42", Action: "response", LocalPath: dest}
	_, err := b.execute(t.Context(), req)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dest)
	if err != nil || string(data) != payload {
		t.Fatal("recording bytes changed")
	}
	if _, err := b.execute(t.Context(), req); err == nil {
		t.Fatal("overwrote export")
	}
}
