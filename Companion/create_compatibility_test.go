package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

	api "github.com/discobox-ai/discobox/api/gen"
)

const legacyCreatedBox = `{"harnessConfig":{"configCommand":["claude"],"configured":true,"futureHarnessField":{}},"id":"created-box","projectId":"p","displayName":"Created","config":{"name":"Created","futureConfigField":true,"user":{"unusedLegacyProperty":true}},"runtime":{"state":"ready","upgrade":{"targetImage":"legacy-image","targetImageDigest":"sha256:fixture","futureUpgradeProperty":true},"provisionProgress":{"futureProgressProperty":true},"futureRuntimeField":true},"futureBoxField":true}`

func TestSourceDeliveryIgnoresUpgradeMetadataAndPreservesSourceState(t *testing.T) {
	var generated api.SandboxUpgrade
	if err := json.Unmarshal([]byte(`{"targetImage":"legacy-image"}`), &generated); err == nil || !strings.Contains(err.Error(), "targetImage") {
		t.Fatalf("fixture does not reproduce strict upgrade decoder rejection: %v", err)
	}
	data := `{"id":"created-box","projectId":"p","poolId":"pool","config":{"source":{"kind":"git","url":"https://example.test/project.git","delivery":"cache","cacheKey":"remote/project","checkout":{"commit":"abcdef"},"futureSourceField":true}},"runtime":{"state":"failed","displayState":"repairing","upgrade":{"targetImage":"legacy-image"},"sourceDeliveries":{"primary":{"status":"needs_credential","host":"example.test","futureField":true}}}}`
	box, err := decodeDeliverySandbox([]byte(data), "p", "created-box")
	if err != nil {
		t.Fatal(err)
	}
	source, sourceOK := box.Config.Source.Get()
	states, statesOK := box.Runtime.SourceDeliveries.Get()
	if !sourceOK || !statesOK || box.PoolId.Or("") != "pool" || source.CacheKey.Or("") != "remote/project" || source.Checkout.Value.Commit.Or("") != "abcdef" || states["primary"].Status != "needs_credential" || box.Runtime.DisplayState.Or("") != "repairing" {
		t.Fatalf("source-delivery state lost: %+v", box)
	}
}

func TestCreateAcceptsLegacyHarnessSnapshotAndPreservesReceiptWithoutRetry(t *testing.T) {
	var generated api.Sandbox
	if err := json.Unmarshal([]byte(legacyCreatedBox), &generated); err == nil || !strings.Contains(err.Error(), "configCommand") {
		t.Fatalf("fixture does not reproduce strict SDK rejection: %v", err)
	}
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	creates := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/projects/p/harness-configs/h":
			return reply(`{"id":"h","configured":true}`), nil
		case r.Method == "GET" && r.URL.Path == "/projects/p":
			return reply(`{}`), nil
		case r.Method == "POST" && r.URL.Path == "/projects/p/sandboxes":
			creates++
			result := reply(legacyCreatedBox)
			result.StatusCode = http.StatusAccepted
			return result, nil
		default:
			t.Fatalf("unexpected operation %s %s", r.Method, r.URL)
			return nil, nil
		}
	})
	result, err := b.createBox(t.Context(), request{ProjectID: "p", HarnessID: "h"})
	if err != nil || creates != 1 || result.Status != http.StatusAccepted || string(result.Body) != legacyCreatedBox {
		t.Fatalf("creation receipt lost or retried: status=%d creates=%d err=%v", result.Status, creates, err)
	}
}

func TestSourceDeliveryReadsIgnoreUnrelatedSnapshotFieldsAndKeepIdentity(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	reads := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		reads++
		if r.Method != "GET" || r.URL.Path != "/projects/p/sandboxes/created-box" {
			t.Fatalf("unexpected operation %s %s", r.Method, r.URL)
		}
		return reply(legacyCreatedBox), nil
	})
	client := sourceDeliveryClient{bridge: b}
	result, err := client.GetSandbox(t.Context(), api.GetSandboxParams{ProjectId: "p", SandboxId: "created-box"})
	box, ok := result.(*api.Sandbox)
	if err != nil || !ok || reads != 1 || box.ID != "created-box" || box.Runtime.State != api.SandboxRuntimeStateReady {
		t.Fatalf("source read rejected legacy snapshot: %T %v reads=%d", result, err, reads)
	}
	for _, data := range []string{
		`{"id":"other-box","projectId":"p","config":{},"runtime":{"state":"ready"}}`,
		`{"id":"created-box","projectId":"other-project","config":{},"runtime":{"state":"ready"}}`,
		`{"id":"../unsafe","projectId":"p","config":{},"runtime":{"state":"ready"}}`,
		`{"id":"created-box","projectId":"p","config":{},"runtime":null}`,
		`{"id":"created-box","projectId":"p","config":{},"runtime":{"state":123}}`,
	} {
		if _, err := decodeDeliverySandbox([]byte(data), "p", "created-box"); err == nil {
			t.Fatalf("accepted invalid source-delivery state: %s", data)
		}
	}
}

func TestCreateTransportFailureStillReportsAmbiguityAndNeverRetries(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	creates := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "GET" {
			return reply(`{"configured":true}`), nil
		}
		creates++
		return nil, errors.New("response lost after creation")
	})
	_, err := b.createBox(context.Background(), request{ProjectID: "p", HarnessID: "h"})
	if creates != 1 || err == nil || !strings.Contains(err.Error(), "creation may have succeeded") {
		t.Fatalf("ambiguous mutation was retried or hidden: %v, creates=%d", err, creates)
	}
}
