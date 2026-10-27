package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDesktopProxyAdaptsOnlyModuleAndKeepsPage(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/app.js" {
			w.Header().Set("Content-Type", "text/javascript")
			w.Header().Set("ETag", "original")
			io.WriteString(w, "const state = {connected:false};")
			return
		}
		io.WriteString(w, "original viewer and annotations")
	}))
	defer upstream.Close()
	handler, err := desktopProxy(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httptest.NewServer(handler)
	defer proxy.Close()
	res, err := http.Get(proxy.URL + "/app.js")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !strings.HasPrefix(string(data), "const state =") || !strings.Contains(string(data), "window.discoboxNative") || res.Header.Get("ETag") != "" {
		t.Fatalf("unadapted module: %s", data)
	}
	res, err = http.Get(proxy.URL)
	if err != nil {
		t.Fatal(err)
	}
	data, _ = io.ReadAll(res.Body)
	res.Body.Close()
	if string(data) != "original viewer and annotations" {
		t.Fatalf("replaced original page: %s", data)
	}
	request, _ := http.NewRequest("GET", proxy.URL, nil)
	request.Host = "attacker.invalid"
	res, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusForbidden {
		t.Fatal("accepted unrelated host")
	}
}
func TestDesktopProxyRejectsNonlocalTargets(t *testing.T) {
	for _, raw := range []string{"http://example.com:80", "http://127.0.0.1", "http://user@127.0.0.1:8080", "http://127.0.0.1:8080/path", "file:///tmp/desktop"} {
		if _, err := desktopProxy(raw); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
}
