package bridge

import (
	"errors"
	"net/http"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func TestCredentialDeleteIsScopedExplicitAndNotRetried(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		b, _ := New("http://fixture")
		b.allowManage = authorized
		calls := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "DELETE" || r.URL.Path != "/projects/p/secrets/secret" {
				t.Fatalf("%s %s", r.Method, r.URL.Path)
			}
			return nil, errors.New("ambiguous connection failure")
		})
		_, err := b.execute(t.Context(), wire.Request{Operation: "deleteSecret", ProjectID: "p", SecretID: "secret"})
		if err == nil {
			t.Fatal("expected refusal/failure")
		}
		expected := 0
		if authorized {
			expected = 1
		}
		if calls != expected {
			t.Fatalf("calls %d", calls)
		}
	}
	b, _ := New("http://fixture")
	b.allowManage = true
	if _, err := b.execute(t.Context(), wire.Request{Operation: "deleteSecret", ProjectID: "p", SecretID: "../other"}); err == nil {
		t.Fatal("accepted invalid credential")
	}
}
