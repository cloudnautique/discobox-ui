package wire

import (
	"context"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/url"
)

// ErrEndpointRedirect refuses every HTTP redirect from the server.
var ErrEndpointRedirect = errors.New("redirects are not accepted")

// ErrorKind classifies a failure for the errorKind field the app uses to
// decide whether to retry. "transport" is retryable; "" is everything else,
// including redirects and certificate failures, which pause recovery.
func ErrorKind(err error) string {
	if errors.Is(err, ErrEndpointRedirect) {
		return ""
	}
	var untrusted x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	if errors.As(err, &untrusted) || errors.As(err, &hostname) || errors.As(err, &invalid) {
		return ""
	}
	var transportError *url.Error
	var networkError net.Error
	if errors.As(err, &transportError) || errors.As(err, &networkError) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "transport"
	}
	return ""
}
