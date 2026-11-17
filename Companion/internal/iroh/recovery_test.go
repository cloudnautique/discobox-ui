package iroh

import (
	"errors"
	"net/http"
	"testing"
)

func TestIrohAdmissionRefusalsPauseRecoveryButNetworkLossDoesNot(t *testing.T) {
	for _, reason := range []string{"peer not enrolled", "server: not authorized", "peer revoked"} {
		if irohProxyErrorStatus(errors.New(reason)) != http.StatusForbidden {
			t.Fatalf("refusal did not pause retries: %s", reason)
		}
	}
	for _, reason := range []string{"deadline exceeded", "server not finished starting", "server shutting down", "IrohError"} {
		if irohProxyErrorStatus(errors.New(reason)) != http.StatusBadGateway {
			t.Fatalf("transient failure stopped recovery: %s", reason)
		}
	}
}
