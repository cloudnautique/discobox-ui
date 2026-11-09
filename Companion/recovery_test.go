package main

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"testing"
)

func TestConnectionErrorKindKeepsCertificateAndValidationFailuresOutOfRetries(t *testing.T) {
	for _, err := range []error{
		&url.Error{Op: "Get", URL: "http://fixture", Err: errors.New("connection refused")},
		fmt.Errorf("existing server request failed: %w", context.DeadlineExceeded),
		io.ErrUnexpectedEOF,
	} {
		if companionErrorKind(err) != "transport" {
			t.Fatalf("network failure was not retryable: %v", err)
		}
	}
	for _, err := range []error{
		errors.New("invalid project"),
		&url.Error{Err: errEndpointRedirect},
		&url.Error{Err: x509.UnknownAuthorityError{}},
		&url.Error{Err: x509.HostnameError{}},
		&url.Error{Err: x509.CertificateInvalidError{}},
	} {
		if companionErrorKind(err) != "" {
			t.Fatal("certificate or request failure became retryable")
		}
	}
}

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
