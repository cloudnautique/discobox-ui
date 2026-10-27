package main

import (
	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
	"github.com/discobox-ai/discobox/pkg/sourceref"
	"testing"
)

func TestGitHubShorthandResolvesWithoutNetwork(t *testing.T) {
	source, err := sandboxcreate.ParseSource("example/project")
	if err != nil {
		t.Fatal(err)
	}
	if source.Kind != sourceref.Git || source.Location != "https://github.com/example/project.git" {
		t.Fatalf("unexpected source: %+v", source)
	}
}
