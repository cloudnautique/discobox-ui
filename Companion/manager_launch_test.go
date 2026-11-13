package main

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

func TestManagerLaunchUsesExplicitAtomicCreateFlagAndRejectsLegacyHosts(t *testing.T) {
	for _, mode := range []string{"enabled", "default-off", "explicit-off", "legacy-refused"} {
		t.Run(mode, func(t *testing.T) {
			b, _ := newBridge("http://fixture", false)
			b.allowManage = true
			writes := 0
			enabled := true
			req := request{ProjectID: "p", HarnessID: "h"}
			if mode != "default-off" {
				req.DiscoboxAPI = &enabled
			}
			if mode == "explicit-off" {
				enabled = false
			}
			b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
				switch {
				case r.Method == "GET" && r.URL.Path == "/projects/p/harness-configs/h":
					if mode == "legacy-refused" {
						return reply(`{"configured":true}`), nil
					}
					return reply(`{"id":"h"}`), nil
				case r.Method == "GET" && r.URL.Path == "/projects/p":
					return reply(`{}`), nil
				case r.Method == "POST" && r.URL.Path == "/projects/p/sandboxes":
					writes++
					raw, _ := io.ReadAll(r.Body)
					var body map[string]json.RawMessage
					if json.Unmarshal(raw, &body) != nil {
						t.Fatal("invalid create")
					}
					flag, present := body["discoboxApi"]
					if mode == "enabled" {
						if string(flag) != "true" {
							t.Fatal("API access missing from atomic create")
						}
					} else if present {
						t.Fatal("default silently enabled API access")
					}
					return reply(legacyCreatedBox), nil
				default:
					t.Fatalf("unexpected request %s %s", r.Method, r.URL)
					return nil, nil
				}
			})
			_, err := b.createBox(t.Context(), req)
			if mode == "legacy-refused" {
				if err == nil || writes != 0 {
					t.Fatal("manager access was silently dropped on legacy host")
				}
			} else if err != nil || writes != 1 {
				t.Fatalf("err=%v writes=%d", err, writes)
			}
		})
	}
}
