package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func (b *bridge) auditBody(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.SandboxID) != nil || validID(req.PoolID) != nil || validID(req.RecordID) != nil {
		return response{}, errors.New("invalid audit identity")
	}
	// Only saveAuditBody writes a local file; a preview never does.
	if save := req.Operation == "saveAuditBody"; save != (req.LocalPath != "") {
		return response{}, errors.New("a recording export needs exactly one destination")
	}
	part := map[string]string{"request": "request-body", "response": "response-body", "stream": "stream"}[req.Action]
	if part == "" {
		return response{}, errors.New("invalid recording part")
	}
	target := b.base + "/api/projects/" + req.ProjectID + "/pools/" + req.PoolID + "/audit/http/" + req.RecordID + "/" + part + "?sandboxId=" + url.QueryEscape(req.SandboxID)
	request, err := http.NewRequestWithContext(ctx, "GET", target, nil)
	if err != nil {
		return response{}, err
	}
	result, err := b.client.Do(request)
	if err != nil {
		return response{}, err
	}
	defer result.Body.Close()
	if result.StatusCode != 200 {
		return response{}, fmt.Errorf("recording unavailable: HTTP %d", result.StatusCode)
	}
	if req.LocalPath != "" {
		file, err := os.CreateTemp(filepath.Dir(req.LocalPath), ".discobox-recording-")
		if err != nil {
			return response{}, err
		}
		defer os.Remove(file.Name())
		count, err := io.Copy(file, result.Body)
		closeErr := file.Close()
		if err != nil {
			return response{}, err
		}
		if closeErr != nil {
			return response{}, closeErr
		}
		if err := publishDownload(file.Name(), req.LocalPath); err != nil {
			return response{}, err
		}
		body, _ := json.Marshal(map[string]any{"bytes": count, "recordingTruncatedFrom": result.Header.Get("X-Discobox-Audit-Truncated"), "format": result.Header.Get("X-Discobox-Audit-Format")})
		return response{Version: protocolVersion, Status: 200, Body: body}, nil
	}
	data, err := io.ReadAll(io.LimitReader(result.Body, 1024*1024+1))
	if err != nil {
		return response{}, err
	}
	truncated := len(data) > 1024*1024
	if truncated {
		data = data[:1024*1024]
	}
	body, _ := json.Marshal(map[string]any{"text": strings.ToValidUTF8(string(data), "�"), "truncated": truncated, "recordingTruncatedFrom": result.Header.Get("X-Discobox-Audit-Truncated"), "format": result.Header.Get("X-Discobox-Audit-Format")})
	return response{Version: protocolVersion, Status: 200, Body: body}, nil
}
