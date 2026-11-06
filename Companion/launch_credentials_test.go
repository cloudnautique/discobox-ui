package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestLaunchCredentialsAreAtomicAndNeverChangeTheSharedHarness(t *testing.T) {
	const token = "fixture-token@with-quotes\"and\\slashes"
	payload, _ := json.Marshal(map[string]any{"secrets": []map[string]string{{"env": "OBOT_MCP_TOKEN", "host": " Demo.On-Obot.AI ", "value": token}}})
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	creates := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/projects/p/harness-configs/h":
			return reply(`{"configured":true}`), nil
		case r.Method == "GET" && r.URL.Path == "/projects/p":
			return reply(`{}`), nil
		case r.Method == "POST" && r.URL.Path == "/projects/p/sandboxes":
			creates++
			data, _ := io.ReadAll(r.Body)
			var body struct {
				Config struct {
					Harness string            `json:"harnessConfigId"`
					Env     map[string]string `json:"env"`
					Secrets []struct {
						Env, Host, Value string
					} `json:"secrets"`
				} `json:"config"`
			}
			if json.Unmarshal(data, &body) != nil || body.Config.Harness != "h" || len(body.Config.Secrets) != 1 {
				t.Fatal("credential missing from the atomic create request")
			}
			secret := body.Config.Secrets[0]
			if secret.Env != "OBOT_MCP_TOKEN" || secret.Host != "demo.on-obot.ai" || secret.Value != token || body.Config.Env["OBOT_MCP_TOKEN"] != "" {
				t.Fatal("token changed or sent through ordinary environment fields")
			}
			return reply(legacyCreatedBox), nil
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
			return nil, nil
		}
	})
	result, err := b.createBox(t.Context(), request{ProjectID: "p", HarnessID: "h", Payload: payload})
	if err != nil || result.Status != 200 || creates != 1 {
		t.Fatalf("create failed or retried: %v, creates=%d", err, creates)
	}
}

func TestLaunchCredentialValidationRunsBeforeAnyRequestsAndNeverEchoesTokens(t *testing.T) {
	for _, payload := range []string{
		`{"secrets":[{"env":"BAD-NAME","host":"example.test","value":"fixture-sensitive"}]}`,
		`{"secrets":[{"env":"TOKEN","host":"https://example.test/path","value":"fixture-sensitive"}]}`,
		`{"secrets":[{"env":"TOKEN","host":"*","value":"fixture-sensitive"}]}`,
		`{"secrets":[{"env":"TOKEN","host":"example.test:443","value":"fixture-sensitive"}]}`,
		`{"secrets":[{"env":"TOKEN","host":"example.test","value":""}]}`,
		`{"secrets":[{"env":"TOKEN","host":"example.test","value":"fixture-sensitive"},{"env":"TOKEN","host":"example.test","value":"fixture-sensitive"}]}`,
		`{"secrets":[{"env":"TOKEN","host":"example.test","value":"fixture-sensitive","raw":true}]}`,
		`{"secrets":[]} {}`,
	} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			t.Fatal("invalid launch credentials triggered a network request")
			return nil, nil
		})
		_, err := b.createBox(t.Context(), request{ProjectID: "p", HarnessID: "h", Payload: []byte(payload)})
		if err == nil || strings.Contains(err.Error(), "fixture-sensitive") {
			t.Fatal("invalid credential accepted or token leaked in error")
		}
	}
}

func TestLaunchCredentialLimitsAndRedaction(t *testing.T) {
	for _, size := range []int{16385, 65537} {
		payload, _ := json.Marshal(map[string]any{"secrets": []map[string]string{{"env": "TOKEN", "host": "example.test", "value": strings.Repeat("a", size)}}})
		if _, err := launchCredentials(payload); err == nil {
			t.Fatal("oversized token accepted")
		}
	}
	payload := []byte(`{"secrets":[{"env":"TOKEN","host":"example.test","value":"fixture-sensitive\"value"}]}`)
	secrets, err := launchCredentials(payload)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(redactLaunchCredentials(string(payload), secrets), "fixture-sensitive") || strings.Contains(redactLaunchCredentials(secrets[0].Value, secrets), "fixture-sensitive") {
		t.Fatal("token leaked through an echoed error")
	}
}
