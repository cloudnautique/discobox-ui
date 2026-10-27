package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type lifecycleTransport func(*http.Request) (*http.Response, error)

func (f lifecycleTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestBoxActionsUseExactRoutesOnce(t *testing.T) {
	for _, tc := range []struct{ action, method, suffix, body string }{
		{"start", "POST", "/start", `{}`}, {"stop", "POST", "/stop", `{}`},
		{"archive", "DELETE", "", ""}, {"unarchive", "POST", "/unarchive", ""},
		{"repair", "POST", "/repair", ""}, {"upgrade", "POST", "/upgrade", `{}`},
		{"rename", "PATCH", "/meta", `{"name":"My box"}`}, {"purge", "POST", "/purge", ""},
	} {
		t.Run(tc.action, func(t *testing.T) {
			mutations, reads := 0, 0
			b := &bridge{base: "http://fixture", allowManage: true, client: &http.Client{Transport: lifecycleTransport(func(r *http.Request) (*http.Response, error) {
				if r.Method == "GET" {
					reads++
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"runtime":{"state":"archived"}}`)), Header: http.Header{}}, nil
				}
				mutations++
				body, _ := io.ReadAll(r.Body)
				if r.Method != tc.method || r.URL.Path != "/projects/p/sandboxes/s"+tc.suffix || string(body) != tc.body {
					t.Fatalf("unexpected mutation: %s %s %s", r.Method, r.URL.Path, body)
				}
				// Errors must be returned, never retried.
				return &http.Response{StatusCode: 409, Body: io.NopCloser(strings.NewReader(`{"detail":"conflict"}`)), Header: http.Header{}}, nil
			})}}
			res, err := b.execute(context.Background(), request{Operation: "boxAction", ProjectID: "p", SandboxID: "s", Action: tc.action, Prompt: "My box"})
			if err != nil || res.Status != 409 || mutations != 1 {
				t.Fatalf("result: %+v %v mutations=%d", res, err, mutations)
			}
			expectedReads := 0
			if tc.action == "purge" {
				expectedReads = 1
			}
			if reads != expectedReads {
				t.Fatalf("reads=%d", reads)
			}
		})
	}
}

func TestBoxActionsFailClosed(t *testing.T) {
	for _, tc := range []struct {
		action, project, box, name string
		permission                 bool
	}{
		{"start", "p", "s", "", false}, {"reconcile", "p", "s", "", true},
		{"stop", "../p", "s", "", true}, {"purge", "p", "../s", "", true},
		{"rename", "p", "s", "bad\nname", true}, {"rename", "p", "s", "", true},
	} {
		b := &bridge{allowManage: tc.permission}
		_, err := b.boxAction(context.Background(), request{Action: tc.action, ProjectID: tc.project, SandboxID: tc.box, Prompt: tc.name})
		if err == nil {
			t.Fatalf("accepted invalid request: %+v", tc)
		}
	}
	b := &bridge{base: "http://fixture", allowManage: true, client: &http.Client{Transport: lifecycleTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Fatal("purged an active box")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"runtime":{"state":"ready","runtimeState":"running"}}`)), Header: http.Header{}}, nil
	})}}
	if _, err := b.boxAction(context.Background(), request{Action: "purge", ProjectID: "p", SandboxID: "s"}); err == nil {
		t.Fatal("accepted purge of active box")
	}
}
