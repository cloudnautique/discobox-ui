package main

import (
	"encoding/json"

	apimodel "github.com/discobox-ai/discobox/api/model"
	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
)

// Reuse the TUI's recorded phase/freshness and readiness semantics. Only
// decorate an inventory already being read; never probe or provision a box.
func withPreparationStatus(body []byte) []byte {
	var list map[string]json.RawMessage
	if json.Unmarshal(body, &list) != nil {
		return body
	}
	var boxes []map[string]json.RawMessage
	if json.Unmarshal(list["sandboxes"], &boxes) != nil {
		return body
	}
	decorated := false
	for _, box := range boxes {
		var head struct {
			DisplayState string `json:"displayState"`
			State        string `json:"state"`
			RuntimeState string `json:"runtimeState"`
		}
		if json.Unmarshal(box["runtime"], &head) != nil {
			continue
		}
		// Healthy inventories stay on the cheap path. Progress is only useful
		// while a box is preparing; do not decode its process/resource reports.
		if head.DisplayState != "starting" && head.DisplayState != "repairing" && head.State != "pending" && head.State != "awaiting_source" &&
			!(head.DisplayState == "" && (head.RuntimeState == "starting" || head.RuntimeState == "suspended")) {
			continue
		}
		raw, _ := json.Marshal(struct {
			Runtime json.RawMessage `json:"runtime"`
		}{box["runtime"]})
		// The generated whole-resource decoder rejects future fields. Decode a
		// standard-library view of only runtime, keeping its option fields but
		// not imposing the generated resource's required/unknown-field rules.
		type runtimeWire apimodel.SandboxRuntime
		var snapshot struct {
			Runtime runtimeWire `json:"runtime"`
		}
		if json.Unmarshal(raw, &snapshot) != nil {
			continue
		}
		model := apimodel.Sandbox{Runtime: apimodel.SandboxRuntime(snapshot.Runtime)}
		box["preparationStatus"], _ = json.Marshal(string(sandboxcreate.ProvisionStatus(&model)))
		decorated = true
	}
	if !decorated {
		return body
	}
	list["sandboxes"], _ = json.Marshal(boxes)
	result, err := json.Marshal(list)
	if err != nil {
		return body
	}
	return result
}
