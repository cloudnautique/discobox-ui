package main

import (
	"context"
	"encoding/json"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
	"github.com/discobox-ai/discobox/pkg/platform"
	"github.com/discobox-ai/discobox/pkg/sourceref"
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

func TestRepositorySourceNormalizesSSHWithoutChangingTransportOrRef(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"git@github.com:example/private", "ssh://git@github.com/example/private"},
		{"git@github.com:example/private.git", "ssh://git@github.com/example/private.git"},
		{"git@gitlab.com:group/private.git", "ssh://git@gitlab.com/group/private.git"},
		{"git@example.test:repos/private.git", "ssh://git@example.test/~/repos/private.git"},
		{"git@example.test:/srv/git/private.git", "ssh://git@example.test/srv/git/private.git"},
		{"git@example.test:~owner/private.git", "ssh://git@example.test/~owner/private.git"},
		{"git@github.com:example/private.git@feature/files//src/app", "ssh://git@github.com/example/private.git@feature/files//src/app"},
		{"ssh://git@example.test:2222/repos/private.git", "ssh://git@example.test:2222/repos/private.git"},
		{"https://github.com/example/private.git", "https://github.com/example/private.git"},
		{"example/private", "https://github.com/example/private.git"},
	} {
		t.Run(tc.input, func(t *testing.T) {
			got, err := repositorySource(tc.input)
			if err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
			source, err := sourceref.Parse(got)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := url.Parse(source.Location); err != nil {
				t.Fatalf("normalized source is not an API URI: %v", err)
			}
		})
	}
	for _, input := range []string{"", "/tmp/private", "./private", "git@github.com:"} {
		if got, err := repositorySource(input); err == nil {
			t.Fatalf("accepted invalid remote %q as %q", input, got)
		}
	}
}

// Exercise upstream source resolution and API serialization together. A local
// SSH stand-in serves a temporary Git repository: no network or real credentials.
func TestSSHSourceBuildsAnAPICreationBody(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("Git is required for the source-resolution integration check")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_TERMINAL_PROMPT", "0")
	t.Setenv("DISCOBOX_HOST_ID", "fixture-host")
	repo := filepath.Join(t.TempDir(), "repository")
	runGit := func(args ...string) string {
		t.Helper()
		output, err := exec.Command(git, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("fixture Git operation failed: %v: %s", err, output)
		}
		return strings.TrimSpace(string(output))
	}
	runGit("init", "--initial-branch=main", repo)
	runGit("-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture")
	commit := runGit("-C", repo, "rev-parse", "HEAD")
	ssh := filepath.Join(t.TempDir(), "ssh")
	if err := os.WriteFile(ssh, []byte("#!/bin/sh\nexec git-upload-pack \"$DISCOBOX_TEST_SOURCE_REPO\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DISCOBOX_TEST_SOURCE_REPO", repo)
	t.Setenv("GIT_SSH_COMMAND", "'"+strings.ReplaceAll(ssh, "'", "'\\''")+"'")
	t.Setenv("GIT_SSH_VARIANT", "ssh")
	options := sandboxcreate.PromptOptions{Source: "git@github.com:example/private.git", Platform: platform.Platform{OS: "linux", Arch: "arm64"}, IncludeDirty: sandboxcreate.IncludeDirtyNever}
	_, original, err := sandboxcreate.BuildPromptSandboxBody(context.Background(), options)
	if original != nil {
		original.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "first path segment") {
		t.Fatalf("fixture did not reproduce the API serialization failure: %v", err)
	}
	options.Source, err = repositorySource(options.Source)
	if err != nil {
		t.Fatal(err)
	}
	body, local, err := sandboxcreate.BuildPromptSandboxBody(context.Background(), options)
	if local != nil {
		defer local.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	source, ok := body.Config.Source.Get()
	if !ok || source.URL.Value.Scheme != "ssh" || source.URL.Value.User.Username() != "git" || source.URL.Value.Host != "github.com" || source.Checkout.Value.Commit.Or("") != commit {
		t.Fatalf("source resolution changed SSH authentication or checkout: %+v", source)
	}
	if _, err := json.Marshal(body); err != nil {
		t.Fatalf("source could not serialize into a creation request: %v", err)
	}
}
