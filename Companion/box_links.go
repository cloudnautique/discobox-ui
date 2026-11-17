package main

import (
	"encoding/json"
	"errors"
	"net/url"
	"strings"

	"github.com/discobox-ai/discobox/pkg/endpoint"
)

// Parse upstream's address grammar without resolving DNS or dialing an address
// from terminal output. Only existing UI connections are candidates.
func parseBoxLink(req request) (response, error) {
	if len(req.Link) > 8192 {
		return response{}, errors.New("the box link is too long")
	}
	u, err := url.Parse(req.Link)
	if err != nil || u.User != nil || u.Opaque != "" {
		return response{}, errors.New("invalid box link; credentials are not accepted in links")
	}
	address, ok, err := endpoint.ParseSandboxAddress(req.Link)
	if err != nil || !ok {
		return response{}, errors.New("invalid box link; use discobox:///<box-id> or discobox://<server>/<box-id>")
	}
	if err := validID(address.Sandbox); err != nil {
		return response{}, errors.New("the box link contains an invalid box ID")
	}
	var candidates []string
	if len(req.Payload) > 0 {
		if err := json.Unmarshal(req.Payload, &candidates); err != nil || len(candidates) > 256 {
			return response{}, errors.New("invalid list of connected computers")
		}
	}
	matched := []string{}
	peer := ""
	if !address.Local() {
		key := boxLinkServerKey(address.Server)
		parsed, _ := endpoint.Parse(address.Server)
		if parsed.Scheme == "iroh" {
			if id, err := parsed.IrohID(); err == nil {
				peer = id.String()
			}
		}
		for _, candidate := range candidates {
			if key != "" && boxLinkServerKey(candidate) == key {
				matched = append(matched, candidate)
			}
		}
	}
	body, err := json.Marshal(map[string]any{
		"sandbox": address.Sandbox, "local": address.Local(), "matches": matched, "peerID": peer,
	})
	return response{Status: 200, Body: body}, err
}

func boxLinkServerKey(raw string) string {
	parsed, err := endpoint.Parse(raw)
	if err != nil {
		return ""
	}
	if parsed.Scheme == "iroh" {
		return "iroh:" + parsed.Value
	}
	u, err := url.Parse(parsed.Value)
	if parsed.Scheme == endpoint.SchemeDiscobox {
		// Compare unresolved DNS names literally; never look them up here.
		u, err = url.Parse(raw)
		if err == nil {
			u.Scheme = "https"
		}
	}
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return ""
	}
	u.Host = strings.ToLower(u.Host)
	if (u.Scheme == "https" && u.Port() == "443") || (u.Scheme == "http" && u.Port() == "80") {
		u.Host = u.Hostname()
		if strings.Contains(u.Host, ":") {
			u.Host = "[" + u.Host + "]"
		}
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u.String()
}
