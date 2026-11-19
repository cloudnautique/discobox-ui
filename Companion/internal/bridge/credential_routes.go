package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/secretroute"
)

type credentialRouteList struct {
	Lines  []string            `json:"lines"`
	Routes []secretroute.Route `json:"routes"`
}

// Use the same grammar and normalization as the Discobox CLI. Refuse unknown
// fields so a newer server's restrictions cannot disappear on a round trip.
func credentialRoutes(raw json.RawMessage, allowText bool) (credentialRouteList, error) {
	var rows []json.RawMessage
	list := credentialRouteList{Lines: []string{}, Routes: []secretroute.Route{}}
	if err := json.Unmarshal(raw, &rows); err != nil || rows == nil {
		return list, errors.New("expected a credential route list")
	}
	seen := make(map[string]bool)
	for i, row := range rows {
		var route secretroute.Route
		var err error
		if allowText && row[0] == '"' {
			var line string
			if err = json.Unmarshal(row, &line); err == nil {
				route, err = secretroute.Parse(line)
			}
		} else {
			decoder := json.NewDecoder(bytes.NewReader(row))
			decoder.DisallowUnknownFields()
			if err = decoder.Decode(&route); err == nil {
				route, err = secretroute.Normalize(route)
			}
		}
		if err != nil {
			return list, fmt.Errorf("route %d: %w", i+1, err)
		}
		line := secretroute.Format(route)
		if !seen[line] {
			list.Lines = append(list.Lines, line)
			list.Routes = append(list.Routes, route)
			seen[line] = true
		}
	}
	return list, nil
}

// Local conversion only. The editor can preview routes without writing a secret.
func previewCredentialRoutes(_ *Bridge, _ context.Context, req wire.Request) (wire.Response, error) {
	list, err := credentialRoutes(req.Payload, true)
	if err != nil {
		return wire.Response{}, err
	}
	body, err := json.Marshal(list)
	return wire.Response{Status: 200, Body: body}, err
}
