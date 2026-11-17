package desktop

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
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

// runBridge evaluates desktop_bridge.js under Node with a fake WebKit handler
// and manual timers. `prelude` declares the viewer's module state (or not);
// `steps` runs after the script and may call tick() and mutate state.
func runBridge(t *testing.T, prelude, steps string) []map[string]any {
	t.Helper()
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed")
	}
	harness := `
const posts = [], timers = new Map(); let nextTimer = 1;
globalThis.window = {webkit: {messageHandlers: {discoboxDesktop: {postMessage: m => posts.push(m)}}}};
globalThis.document = {activeElement: null, addEventListener() {}};
globalThis.setInterval = f => { timers.set(nextTimer, f); return nextTimer++; };
globalThis.clearInterval = id => timers.delete(id);
const tick = (n = 1) => { for (let i = 0; i < n; i++) for (const f of [...timers.values()]) f(); };
` + prelude + "\n" + string(desktopBridgeJS) + "\n" + steps + `
console.log(JSON.stringify({posts, timers: timers.size}));
`
	path := filepath.Join(t.TempDir(), "bridge.js")
	if err := os.WriteFile(path, []byte(harness), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(node, path).Output()
	if err != nil {
		t.Fatalf("node: %v", err)
	}
	var result struct {
		Posts  []map[string]any
		Timers int
	}
	if err := json.Unmarshal(out, &result); err != nil {
		t.Fatalf("decode %s: %v", out, err)
	}
	result.Posts = append(result.Posts, map[string]any{"timers": float64(result.Timers)})
	return result.Posts
}

func TestDesktopBridgePostsReadinessOnlyWhenItChanges(t *testing.T) {
	posts := runBridge(t, `var state = {rfb: null, connected: false};
const listeners = [];
const rfb = () => ({addEventListener: (kind, f) => listeners.push(kind)});`, `
tick(5);
state.rfb = rfb(); state.connected = true; tick(5);
state.connected = false; tick(3);
state.rfb = rfb(); state.connected = true; tick(3);
posts.push({kind: 'listeners', value: listeners.join(',')});`)
	var got []string
	for _, post := range posts[:len(posts)-1] {
		got = append(got, fmt.Sprint(post["kind"], "=", post["value"]))
	}
	want := []string{"ready=false", "ready=true", "ready=false", "ready=true", "listeners=clipboard,clipboard"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("posts = %v, want %v", got, want)
	}
	if posts[len(posts)-1]["timers"] != float64(1) {
		t.Fatal("stopped sampling a supported page")
	}
}

func TestDesktopBridgeReportsUnsupportedPageOnceAndStops(t *testing.T) {
	posts := runBridge(t, "", "tick(10);")
	if len(posts) != 2 || posts[0]["kind"] != "error" || !strings.Contains(fmt.Sprint(posts[0]["value"]), "does not support") {
		t.Fatalf("posts = %v, want one error", posts)
	}
	if posts[1]["timers"] != float64(0) {
		t.Fatal("kept sampling an unsupported page")
	}
}
