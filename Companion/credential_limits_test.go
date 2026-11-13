package main

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

func TestSharedCredentialLimitsRequireFreshMetadataAndExactProtocol(t *testing.T) {
	for _, legacy := range []bool{false, true} {
		field := "maxBindingTTLSeconds"
		if legacy {
			field = "maxGrantTTLSeconds"
		}
		metadata, _ := json.Marshal(map[string]any{"id": "s", field: 3600})
		for _, mode := range []string{"save", "stale", "value", "wrong-protocol", "unauthorized"} {
			t.Run(field+"/"+mode, func(t *testing.T) {
				b, _ := newBridge("http://fixture", false)
				b.allowManage = mode != "unauthorized"
				writes := 0
				b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
					if r.Method == "GET" {
						return reply(string(metadata)), nil
					}
					if r.Method != "PATCH" || r.URL.Path != "/projects/p/secrets/s" {
						t.Fatalf("unexpected request %s %s", r.Method, r.URL)
					}
					writes++
					var body map[string]json.RawMessage
					data, _ := io.ReadAll(r.Body)
					if json.Unmarshal(data, &body) != nil || len(body) != 1 || body[field] == nil {
						t.Fatalf("unsafe update %s", data)
					}
					return reply(string(metadata)), nil
				})
				expected := json.RawMessage(metadata)
				limits := map[string]any{field: 1800}
				if mode == "stale" {
					expected = json.RawMessage(`{"id":"s","revision":0}`)
				}
				if mode == "value" {
					limits["value"] = map[string]string{"token": "forbidden"}
				}
				if mode == "wrong-protocol" {
					limits = map[string]any{"maxGrantTTLSeconds": 1800}
					if legacy {
						limits = map[string]any{"maxBindingTTLSeconds": 1800}
					}
				}
				payload, _ := json.Marshal(map[string]any{"expectedSecret": expected, "limits": limits})
				res, err := b.execute(t.Context(), request{Operation: "updateSecretLimits", ProjectID: "p", RequestID: "s", Payload: payload})
				if mode == "save" {
					if err != nil || res.Status != 200 || writes != 1 {
						t.Fatalf("save=%v status=%d writes=%d", err, res.Status, writes)
					}
				} else if err == nil || writes != 0 {
					t.Fatalf("unsafe %s accepted: err=%v writes=%d", mode, err, writes)
				}
			})
		}
	}
}
