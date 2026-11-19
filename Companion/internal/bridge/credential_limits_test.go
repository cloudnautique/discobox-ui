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

func TestSharedRoutesSurviveEditSaveAndReadback(t *testing.T) {
	lines := []string{
		"api.example.test/repos/demo/project,/repos/demo/project/**",
		"GET api.example.test/repos/fork/project,/repos/fork/project/**",
		"GET api.example.test/search/issues,/user",
		"api.example.test/graphql graphql=query",
		"api.example.test/graphql graphql=mutation:markPullRequestReadyForReview",
		"GET,POST git.example.test/demo/project.git/info/refs,/demo/project.git/git-upload-pack",
		"GET git.example.test/demo/project/**",
		"api.example.test/repos/demo/project/pulls/*/merge=blocked",
	}
	raw, _ := json.Marshal(lines)
	b, _ := New("http://fixture")
	b.allowManage = true
	preview, err := b.execute(t.Context(), wire.Request{Operation: "credentialRoutes", Payload: raw})
	var draft credentialRouteList
	if err != nil || json.Unmarshal(preview.Body, &draft) != nil || len(draft.Routes) != len(lines) {
		t.Fatalf("preview: %s, %v", preview.Body, err)
	}
	if !draft.Routes[7].Blocked || draft.Routes[4].GraphQL.Fields[0] != "markPullRequestReadyForReview" {
		t.Fatalf("lost restrictions: %v", draft)
	}
	stored := map[string]any{"id": "s", "maxBindingTTLSeconds": 3600, "routes": draft.Routes[:1], "routeConstraints": [][]any{{}}}
	data, _ := json.Marshal(stored)
	update, _ := json.Marshal(map[string]any{"expectedSecret": json.RawMessage(data), "limits": map[string]any{"routes": draft.Routes}})
	writes := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == http.MethodPut {
			var body map[string]json.RawMessage
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body) != 1 || body["routes"] == nil {
				t.Fatalf("expected only routes: %v, %v", body, err)
			}
			stored["routes"] = body["routes"]
			writes++
		}
		data, _ := json.Marshal(stored)
		return reply(string(data)), nil
	})
	result, err := b.execute(t.Context(), wire.Request{Operation: "updateSecretLimits", ProjectID: "p", SecretID: "s", Payload: update})
	if err != nil || writes != 1 || result.Status != http.StatusOK {
		t.Fatalf("save status=%d writes=%d err=%v", result.Status, writes, err)
	}
	var confirmed struct {
		Routes json.RawMessage `json:"routes"`
	}
	if err := json.Unmarshal(result.Body, &confirmed); err != nil {
		t.Fatal(err)
	}
	reopened, err := b.execute(t.Context(), wire.Request{Operation: "credentialRoutes", Payload: confirmed.Routes})
	if err != nil || string(reopened.Body) != string(preview.Body) {
		t.Fatalf("reopen: %v, %s", err, reopened.Body)
	}
}

func TestSharedRouteUpdateRejectsUnknownRestrictionsAndUnverifiedWrites(t *testing.T) {
	for _, test := range []struct {
		name, field, routes, readback string
		writes                        int
		ok                            bool
	}{
		{"unknown", "maxBindingTTLSeconds", `[{"hosts":["a.test"],"newRestriction":true}]`, "", 0, false},
		{"malformed", "maxBindingTTLSeconds", `[{"paths":["/"]}]`, "", 0, false},
		{"null", "maxBindingTTLSeconds", "null", "", 0, false},
		{"legacy", "maxGrantTTLSeconds", "[]", "", 0, false},
		{"noop", "maxBindingTTLSeconds", `[{"hosts":["a.test"],"blocked":true}]`, `[{"hosts":["a.test"]}]`, 1, false},
		{"clear", "maxBindingTTLSeconds", "[]", "", 1, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			b, _ := New("http://fixture")
			b.allowManage = true
			stored := map[string]any{"id": "s", test.field: 3600, "routes": json.RawMessage(`[{"hosts":["a.test"]}]`)}
			data, _ := json.Marshal(stored)
			update, _ := json.Marshal(map[string]any{"expectedSecret": json.RawMessage(data), "limits": map[string]any{"routes": json.RawMessage(test.routes)}})
			writes := 0
			b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
				if r.Method == http.MethodPut {
					writes++
					if test.readback == "" {
						delete(stored, "routes")
					} else {
						stored["routes"] = json.RawMessage(test.readback)
					}
				}
				data, _ := json.Marshal(stored)
				return reply(string(data)), nil
			})
			_, err := b.execute(t.Context(), wire.Request{Operation: "updateSecretLimits", ProjectID: "p", SecretID: "s", Payload: update})
			if (err == nil) != test.ok || writes != test.writes {
				t.Fatalf("writes=%d err=%v", writes, err)
			}
		})
	}
}
