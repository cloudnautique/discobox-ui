package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestConsentUsesItsOwnRoutesAndRechecksPending(t *testing.T) {
	for _, kind := range []string{"apiAccess", "adoption"} {
		for _, pending := range []bool{true, false} {
			b, _ := newBridge("http://fixture", false)
			b.allowManage = true
			resource := "api-access-requests"
			if kind == "adoption" {
				resource = "adoption-requests"
			}
			writes := 0
			b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
				want := "/projects/p/" + resource + "/ask"
				if r.Method == "GET" {
					if r.URL.Path != want {
						t.Fatalf("read %s", r.URL.Path)
					}
					status := "approved"
					if pending {
						status = "pending"
					}
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"status":"` + status + `"}`)), Header: make(http.Header)}, nil
				}
				writes++
				if r.Method != "POST" || r.URL.Path != want+"/approve" {
					t.Fatalf("write %s %s", r.Method, r.URL.Path)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}, nil
			})
			_, err := b.execute(t.Context(), request{Operation: "answer", ProjectID: "p", RequestID: "ask", Kind: kind, Action: "approve"})
			if (err == nil) != pending || writes != map[bool]int{true: 1, false: 0}[pending] {
				t.Fatalf("%s pending=%v writes=%d err=%v", kind, pending, writes, err)
			}
		}
	}
}

func TestRefreshNeverRunsCommandsAndRechecksPending(t *testing.T) {
	for _, action := range []string{"refresh", "deny"} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		writes := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			body := `{}`
			if r.Method == "GET" {
				if r.URL.RequestURI() != "/projects/p/secret-refresh-requests?status=pending" {
					t.Fatalf("read %s", r.URL)
				}
				body = `{"secretRefreshRequests":[{"id":"ask","secretId":"sec","status":"pending"}]}`
			} else {
				writes++
				want := "/projects/p/secret-refresh-requests/ask/dismiss"
				if action == "refresh" {
					want = "/projects/p/secrets/sec/refresh"
				}
				if r.URL.Path != want {
					t.Fatalf("write %s", r.URL)
				}
				data, _ := io.ReadAll(r.Body)
				if action == "refresh" && (!strings.Contains(string(data), `"via":"entered"`) || strings.Contains(string(data), "command")) {
					t.Fatalf("unsafe payload %s", data)
				}
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
		})
		_, err := b.execute(t.Context(), request{Operation: "answer", ProjectID: "p", RequestID: "ask", Kind: "refresh", Action: action, Payload: []byte(`{"value":"replacement","command":["never-execute"]}`)})
		if err != nil || writes != 1 {
			t.Fatalf("writes=%d err=%v", writes, err)
		}
	}
	b, _ := newBridge("http://fixture", false)
	if _, err := b.execute(t.Context(), request{Operation: "answer", ProjectID: "p", RequestID: "ask", Kind: "apiAccess", Action: "approve"}); err == nil {
		t.Fatal("consent write without explicit manage permission")
	}
}
