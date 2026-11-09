package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
)

func (b *bridge) poolConfiguration(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.PoolID) != nil {
		return response{}, errors.New("invalid pool destination")
	}
	path := "/projects/" + req.ProjectID + "/pools/" + req.PoolID
	if req.Operation == "poolConfiguration" {
		return b.call(ctx, "GET", path, nil)
	}
	if !b.allowManage {
		return response{}, errors.New("changing pool network settings requires explicit permission")
	}
	var input struct {
		Proxy    json.RawMessage `json:"proxy"`
		Expected json.RawMessage `json:"expectedProxy"`
	}
	decoder := json.NewDecoder(bytes.NewReader(req.Payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || len(input.Proxy) == 0 || len(input.Expected) == 0 {
		return response{}, errors.New("invalid pool network update")
	}
	if string(input.Proxy) != "null" {
		var fields map[string]json.RawMessage
		if json.Unmarshal(input.Proxy, &fields) != nil || fields == nil {
			return response{}, errors.New("proxy must be an object or null")
		}
		for key := range fields {
			switch key {
			case "mode", "http", "https", "noProxy", "caPem", "clearHttpCredentials", "clearHttpsCredentials":
			default:
				return response{}, errors.New("unsupported proxy setting")
			}
		}
	}
	current, err := b.call(ctx, "GET", path, nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	var pool map[string]json.RawMessage
	if json.Unmarshal(current.Body, &pool) != nil {
		return response{}, errors.New("invalid pool response")
	}
	canon := func(raw json.RawMessage) string {
		var value any
		_ = json.Unmarshal(raw, &value)
		data, _ := json.Marshal(value)
		return string(data)
	}
	if canon(pool["proxy"]) != canon(input.Expected) {
		return response{}, errors.New("pool network settings changed elsewhere; reload before saving")
	}
	// PATCH only the whole proxy override. Omission preserves every other pool
	// property, and an explicit null removes the override. Never restart a pool.
	payload, _ := json.Marshal(map[string]json.RawMessage{"proxy": input.Proxy})
	res, err := b.call(ctx, "PATCH", path, payload)
	// Error responses can quote invalid credential-bearing URLs or PEM input.
	if err != nil {
		return response{}, errors.New("pool network update failed; reload to check whether it was applied")
	}
	if res.Status >= 400 {
		res.Body = []byte(`{"detail":"Pool network update was refused. Check the proxy URL, mode and CA certificates, then reload the pool."}`)
	}
	return res, nil
}
