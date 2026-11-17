package wire

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net/url"
	"testing"
)

func TestConnectionErrorKindKeepsCertificateAndValidationFailuresOutOfRetries(t *testing.T) {
	for _, err := range []error{
		&url.Error{Op: "Get", URL: "http://fixture", Err: errors.New("connection refused")},
		fmt.Errorf("existing server request failed: %w", context.DeadlineExceeded),
		io.ErrUnexpectedEOF,
	} {
		if ErrorKind(err) != "transport" {
			t.Fatalf("network failure was not retryable: %v", err)
		}
	}
	for _, err := range []error{errors.New("invalid project"), &url.Error{Err: ErrEndpointRedirect}} {
		if ErrorKind(err) != "" {
			t.Fatal("request failure became retryable")
		}
	}
	// Certificate failures are named, so the app asks for action instead of retrying.
	for _, err := range []error{
		&url.Error{Err: x509.UnknownAuthorityError{}},
		&url.Error{Err: x509.HostnameError{}},
		&url.Error{Err: x509.CertificateInvalidError{}},
	} {
		if ErrorKind(err) != KindCertificate {
			t.Fatalf("certificate failure was not classified: %v", err)
		}
	}
}
