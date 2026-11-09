package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPreparationUsesTUIReadinessWithoutBlockingOnAsyncFeatures(t *testing.T) {
	raw := []byte(`{"futureInventoryField":true,"sandboxes":[{"id":"box","futureBoxField":true,"runtime":{"state":"ready","generation":1,"observedGeneration":1,"runtimeState":"running","displayState":"starting","agentStatus":{"provision":{"ready":false,"state":"provisioning","features":{"core":{"state":"provisioning","step":"install"},"background-download":{"state":"provisioning","step":"downloading","async":true}}}}}}]}`)
	var out struct {
		Sandboxes []struct {
			Status string `json:"preparationStatus"`
			Future bool   `json:"futureBoxField"`
		} `json:"sandboxes"`
		Future bool `json:"futureInventoryField"`
	}
	if err := json.Unmarshal(withPreparationStatus(raw), &out); err != nil {
		t.Fatal(err)
	}
	if !out.Future || !out.Sandboxes[0].Future {
		t.Fatal("decoration dropped upstream fields")
	}
	if out.Sandboxes[0].Status != "provisioning core / install" || strings.Contains(out.Sandboxes[0].Status, "background") {
		t.Fatalf("incorrect gate %q", out.Sandboxes[0].Status)
	}
}

func TestRunningInventoryKeepsItsOriginalBytes(t *testing.T) {
	raw := []byte(`{"sandboxes":[{"id":"live","runtime":{"state":"ready","displayState":"running","resources":{"future-report":{"processes":[1,2,3]}}}}],"futureInventoryField":true}`)
	if string(withPreparationStatus(raw)) != string(raw) {
		t.Fatal("a steady-state inventory was needlessly reconstructed")
	}
}
