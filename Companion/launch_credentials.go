package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	api "github.com/discobox-ai/discobox/api/gen"
)

var launchEnvName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var launchHostName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

// Inline secrets have the same wire shape in v0.18 and current servers. They
// are part of the single create request, so the harness starts with its secret
// assignments. Never feed token text through CLI KEY=VALUE@HOST parsing.
func launchCredentials(payload json.RawMessage) ([]api.SandboxSecretInput, error) {
	if len(payload) == 0 {
		return nil, nil
	}
	if len(payload) > 65536 {
		return nil, errors.New("launch credentials exceed 64 KB")
	}
	var input struct {
		Secrets []struct {
			Env   string `json:"env"`
			Host  string `json:"host"`
			Value string `json:"value"`
		} `json:"secrets"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return nil, errors.New("invalid launch credentials")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("invalid launch credentials")
	}
	if len(input.Secrets) > 16 {
		return nil, errors.New("add at most 16 credentials per box")
	}
	seen := make(map[string]bool)
	secrets := make([]api.SandboxSecretInput, 0, len(input.Secrets))
	for i, item := range input.Secrets {
		env, host := strings.TrimSpace(item.Env), strings.ToLower(strings.TrimSpace(item.Host))
		if len(env) > 128 || !launchEnvName.MatchString(env) || seen[env] {
			return nil, fmt.Errorf("credential %d needs a valid, unique environment variable", i+1)
		}
		if len(host) > 253 || !launchHostName.MatchString(host) {
			return nil, fmt.Errorf("credential %d needs a destination hostname without a scheme, port, or path", i+1)
		}
		for _, label := range strings.Split(host, ".") {
			if len(label) > 63 {
				return nil, fmt.Errorf("credential %d has an invalid destination hostname", i+1)
			}
		}
		if strings.TrimSpace(item.Value) == "" || len(item.Value) > 16384 || strings.ContainsRune(item.Value, 0) {
			return nil, fmt.Errorf("credential %d needs a token of at most 16 KB", i+1)
		}
		seen[env] = true
		secrets = append(secrets, api.SandboxSecretInput{Env: env, Host: api.NewOptString(host), Value: item.Value})
	}
	return secrets, nil
}

// Do not surface a token echoed by an error response.
// Replace the JSON-escaped representation as well as plain text.
func redactLaunchCredentials(text string, secrets []api.SandboxSecretInput) string {
	for _, secret := range secrets {
		escaped, _ := json.Marshal(secret.Value)
		text = strings.ReplaceAll(text, string(escaped[1:len(escaped)-1]), "<redacted>")
		text = strings.ReplaceAll(text, secret.Value, "<redacted>")
	}
	return text
}
