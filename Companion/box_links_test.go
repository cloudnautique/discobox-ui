package main

import (
	"crypto/ed25519"
	"encoding/json"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/pkg/endpoint"
)

func TestBoxLinkUsesUpstreamGrammarAndOnlyMatchesExistingEndpoints(t *testing.T) {
	id, _ := endpoint.IrohIDFromPublicKey(fixtureKey(t).Public().(ed25519.PublicKey))
	peer := id.String()
	for _, tc := range []struct {
		raw, candidate, match, wantPeer string
		local                           bool
	}{
		{"discobox:///sbx_research", "unix://", "", "", true},
		{"DISCOBOX:///sbx_research/", "https://other.test", "", "", true},
		{"discobox://" + peer + "/sbx_research?addr=192.0.2.1:1234", "iroh://" + peer, "iroh://" + peer, peer, false},
		{"discobox+http://BOX.test:80/sbx_research", "http://box.test", "http://box.test", "", false},
		{"discobox+https://box.test:443/sbx_research", "https://box.test/", "https://box.test/", "", false},
		{"discobox://box.test/sbx_research", "https://box.test", "https://box.test", "", false},
		{"discobox://unknown.test/sbx_research", "https://known.test", "", "", false},
		{"discobox+http://box.test/sbx_research", "https://box.test", "", "", false},
		{"discobox+http://box.test/sbx_research", "http://box.test/api", "", "", false},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			candidates, _ := json.Marshal([]string{tc.candidate})
			res, err := parseBoxLink(request{Link: tc.raw, Payload: candidates})
			if err != nil {
				t.Fatal(err)
			}
			var got struct {
				Sandbox string
				Local   bool
				Matches []string
				PeerID  string
			}
			if err := json.Unmarshal(res.Body, &got); err != nil {
				t.Fatal(err)
			}
			if got.Sandbox != "sbx_research" || got.Local != tc.local || got.PeerID != tc.wantPeer {
				t.Fatalf("wrong address: %+v", got)
			}
			if tc.match == "" && len(got.Matches) != 0 {
				t.Fatalf("matched unrelated connection: %+v", got)
			}
			if tc.match != "" && (len(got.Matches) != 1 || got.Matches[0] != tc.match) {
				t.Fatalf("lost known connection: %+v", got)
			}
		})
	}
}

func TestBoxLinkRejectsMalformedOrCredentialBearingLinks(t *testing.T) {
	for _, raw := range []string{
		"https://example.test/sbx_research", "discobox://", "discobox:///", "discobox:///a/b",
		"discobox:///sbx_research#desktop", "discobox:///sbx_research?", "discobox:///sbx_research?token=private",
		"discobox://user:private@box.test/sbx_research", "discobox://box.test/sbx_%1b", "discobox://box.test/sbx_a%2fb",
		"discobox+http:///sbx_research", "discobox://d1-typo/sbx_research", strings.Repeat("x", 9000),
	} {
		if _, err := parseBoxLink(request{Link: raw}); err == nil {
			t.Errorf("accepted %q", raw)
		}
	}
	method, path, body, err := route(request{Operation: "serverPeer"})
	if err != nil || method != "GET" || path != "/peer" || body != nil {
		t.Fatalf("identity lookup is not a fixed read: %s %s %v", method, path, err)
	}
}
