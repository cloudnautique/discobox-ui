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

// Error kinds the app decides on; its messages are only for people. They are
// published in protocol.json (ErrorKinds) beside the operations. HTTP 401/403,
// including Iroh enrollment refusals, reach the app as a status, not a kind.
const (
	// KindTransport is a network or transport failure; reads may be retried.
	KindTransport = "transport"
	// KindCertificate is a TLS verification failure; retrying cannot help.
	KindCertificate = "certificate"
)

// ErrorKinds lists every errorKind value the companion reports.
var ErrorKinds = []string{KindCertificate, KindTransport}

// ErrorKind classifies a failure for the errorKind field. "" is every other
// failure, including refused redirects; only transport failures are retried.
func ErrorKind(err error) string {
	if errors.Is(err, ErrEndpointRedirect) {
		return ""
	}
	var untrusted x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	if errors.As(err, &untrusted) || errors.As(err, &hostname) || errors.As(err, &invalid) {
		return KindCertificate
	}
	var transportError *url.Error
	var networkError net.Error
	if errors.As(err, &transportError) || errors.As(err, &networkError) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.ErrUnexpectedEOF) {
		return KindTransport
	}
	return ""
}
