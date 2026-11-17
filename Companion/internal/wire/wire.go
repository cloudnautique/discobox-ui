// Package wire is the companion's stdin/stdout contract with the app: one
// bounded Request in, one Response out, at ProtocolVersion. The operation
// names and permission classes that go with this version live in the bridge
// registry and are published in Companion/protocol.json.
package wire

import "encoding/json"

// ProtocolVersion is the wire version of a bounded request/response. The
// operation names, their permission classes and this version are published in
// protocol.json, which the Go and Swift tests both check against.
const ProtocolVersion = 2

// Request is one bounded request. Each field has one meaning across
// operations; see ARCHITECTURE.md ("Components").
type Request struct {
	DiscoboxAPI *bool           `json:"discoboxAPI,omitempty"`
	RemotePath  string          `json:"remotePath,omitempty"`
	LocalPath   string          `json:"localPath,omitempty"`
	Operation   string          `json:"operation"`
	ProjectID   string          `json:"projectID"`
	SandboxID   string          `json:"sandboxID"`
	ExecID      string          `json:"execID"`
	HarnessID   string          `json:"harnessID,omitempty"`
	PoolID      string          `json:"poolID,omitempty"`
	Repository  string          `json:"repository,omitempty"`
	Prompt      string          `json:"prompt,omitempty"`
	Name        string          `json:"name,omitempty"`
	RequestID   string          `json:"requestID,omitempty"`
	Kind        string          `json:"kind,omitempty"`
	SecretID    string          `json:"secretID,omitempty"`
	RecordID    string          `json:"recordID,omitempty"`
	ToolID      string          `json:"toolID,omitempty"`
	Link        string          `json:"link,omitempty"`
	Action      string          `json:"action,omitempty"`
	Payload     json.RawMessage `json:"payload,omitempty"`
}

// Response is the reply to one Request: the server's status and body, or an
// Error with its ErrorKind.
type Response struct {
	Version   int    `json:"version"`
	Status    int    `json:"status"`
	Body      []byte `json:"body,omitempty"`
	Error     string `json:"error,omitempty"`
	ErrorKind string `json:"errorKind,omitempty"`
}
