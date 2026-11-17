package bridge

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
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
				b, _ := New("http://fixture")
				b.allowManage = mode != "unauthorized"
				writes := 0
				serverMetadata := metadata
				b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
					if r.Method == "GET" {
						return reply(string(serverMetadata)), nil
					}
					if r.Method != "PUT" || r.URL.Path != "/projects/p/secrets/s" {
						t.Fatalf("unexpected request %s %s", r.Method, r.URL)
					}
					writes++
					var body map[string]json.RawMessage
					data, _ := io.ReadAll(r.Body)
					if json.Unmarshal(data, &body) != nil || len(body) != 1 || body[field] == nil {
						t.Fatalf("unsafe update %s", data)
					}
					var stored map[string]json.RawMessage
					_ = json.Unmarshal(serverMetadata, &stored)
					stored[field] = body[field]
					serverMetadata, _ = json.Marshal(stored)
					return reply(string(serverMetadata)), nil
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
				res, err := b.execute(t.Context(), wire.Request{Operation: "updateSecretLimits", ProjectID: "p", SecretID: "s", Payload: payload})
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

// Exercise persistence rather than accepting an HTTP success as a saved value.
func TestCredentialLimitSaveReadsBackWithoutReplayingTheWrite(t *testing.T) {
	for _, field := range []string{"maxBindingTTLSeconds", "maxGrantTTLSeconds"} {
		for _, mode := range []string{"saved", "zero", "noop", "wrong-id", "verification-error", "missing-field", "rejected"} {
			t.Run(field+"/"+mode, func(t *testing.T) {
				b, _ := New("http://fixture")
				b.allowManage = true
				current := map[string]any{"id": "s", field: 1800, "name": "Fixture", "routes": []any{}}
				expected, _ := json.Marshal(current)
				seconds := 7200
				if mode == "zero" {
					seconds = 0
				}
				limits := map[string]any{field: seconds}
				if field == "maxGrantTTLSeconds" {
					limits["host"] = ""
				}
				payload, _ := json.Marshal(map[string]any{"expectedSecret": json.RawMessage(expected), "limits": limits})
				reads, writes := 0, 0
				b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
					if r.Method == http.MethodGet {
						reads++
						if reads > 1 {
							switch mode {
							case "wrong-id":
								current["id"] = "another"
							case "missing-field":
								delete(current, field)
							case "verification-error":
								return nil, io.ErrUnexpectedEOF
							}
						}
						data, _ := json.Marshal(current)
						return reply(string(data)), nil
					}
					if r.Method != http.MethodPut {
						t.Fatalf("update method = %s, want PUT", r.Method)
					}
					writes++
					var update map[string]json.RawMessage
					if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
						t.Fatal(err)
					}
					var saved int
					if err := json.Unmarshal(update[field], &saved); err != nil || saved != seconds {
						t.Fatalf("wrong lifetime body: %s", update[field])
					}
					if mode == "rejected" {
						res := reply(`{"detail":"Access refused"}`)
						res.StatusCode = http.StatusForbidden
						return res, nil
					}
					if mode != "noop" {
						current[field] = seconds
					}
					// A successful write may have no response body. Verify by GET.
					res := reply("")
					res.StatusCode = http.StatusNoContent
					return res, nil
				})
				result, err := b.execute(t.Context(), wire.Request{Operation: "updateSecretLimits", ProjectID: "p", SecretID: "s", Payload: payload})
				if writes != 1 {
					t.Fatalf("writes = %d, want exactly one", writes)
				}
				switch mode {
				case "saved", "zero":
					if err != nil || result.Status != http.StatusOK || reads != 2 {
						t.Fatalf("save: err=%v status=%d reads=%d", err, result.Status, reads)
					}
					var confirmed map[string]any
					if json.Unmarshal(result.Body, &confirmed) != nil || confirmed[field] != float64(seconds) {
						t.Fatalf("saved response: %s", result.Body)
					}
				case "rejected":
					if err != nil || result.Status != http.StatusForbidden || reads != 1 {
						t.Fatalf("rejection: err=%v status=%d reads=%d", err, result.Status, reads)
					}
				default:
					if err == nil {
						t.Fatal("unverified save reported success")
					}
				}
			})
		}
	}
}
