package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type auditRow struct {
	ID      string  `json:"id"`
	Source  string  `json:"source"`
	Time    string  `json:"time"`
	Order   float64 `json:"order"`
	Summary string  `json:"summary"`
	Detail  string  `json:"detail"`
}

// Each requested snapshot is bounded and reports truncation and missing trails.
// The GUI retains/deduplicates snapshots; it never treats missing as empty.
func (b *bridge) audit(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.SandboxID) != nil {
		return response{}, fmt.Errorf("invalid audit target")
	}
	var cursor struct {
		Before map[string]string `json:"before"`
		Since  map[string]string `json:"since"`
		After  map[string]string `json:"after"`
	}
	if len(req.Payload) > 0 {
		if err := json.Unmarshal(req.Payload, &cursor); err != nil {
			return response{}, err
		}
	}
	project := "/projects/" + req.ProjectID
	box := "/api" + project + "/sandboxes/" + req.SandboxID
	trails := []struct{ name, path, key string }{
		{"HTTP", project + "/audit/http?sandboxId=" + req.SandboxID, "exchanges"},
		{"Credentials", project + "/credential-verdicts?sandboxId=" + req.SandboxID, "credentialVerdicts"},
		{"Refresh", project + "/secret-refreshes?sandboxId=" + req.SandboxID, "secretRefreshEvents"},
		{"Hooks", box + "/harness-hooks?", "hooks"},
		{"Execs", box + "/exec-events?", "events"},
	}
	out := struct {
		Records []auditRow        `json:"records"`
		Missing []string          `json:"missing"`
		Before  map[string]string `json:"before"`
		Since   map[string]string `json:"since"`
		After   map[string]string `json:"after"`
		Limited []string          `json:"limited"`
	}{Records: []auditRow{}, Missing: []string{}, Limited: []string{}, Before: map[string]string{}, Since: map[string]string{}, After: map[string]string{}}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, trail := range trails {
		wg.Add(1)
		go func() {
			defer wg.Done()
			query := url.Values{"order": {"desc"}, "limit": {"1000"}}
			if before := cursor.Before[trail.name]; before != "" {
				query.Set("until", before)
			}
			if since := cursor.Since[trail.name]; since != "" {
				query.Set("since", since)
				query.Set("order", "asc")
			}
			if trail.name == "HTTP" && len(cursor.Before) == 0 {
				for pool, id := range cursor.After {
					query.Add("after", pool+":"+id)
				}
			}
			result, err := b.call(ctx, "GET", trail.path+"&"+query.Encode(), nil)
			var payload map[string]json.RawMessage
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				out.Missing = append(out.Missing, trail.name+": "+err.Error())
				return
			}
			if result.Status != 200 {
				out.Missing = append(out.Missing, fmt.Sprintf("%s: HTTP %d", trail.name, result.Status))
				return
			}
			if json.Unmarshal(result.Body, &payload) != nil {
				out.Missing = append(out.Missing, trail.name+": invalid response")
				return
			}
			var records []map[string]any
			if json.Unmarshal(payload[trail.key], &records) != nil {
				out.Missing = append(out.Missing, trail.name+": invalid records")
				return
			}
			if len(records) >= 1000 {
				out.Limited = append(out.Limited, trail.name)
			}
			var pools []struct {
				PoolID string `json:"poolId"`
				Reason string `json:"reason"`
			}
			_ = json.Unmarshal(payload["unavailablePools"], &pools)
			for _, pool := range pools {
				out.Missing = append(out.Missing, "HTTP pool "+pool.PoolID+": "+pool.Reason)
			}
			for _, record := range records {
				value := func(key string) string {
					if v, ok := record[key]; ok && v != nil {
						return fmt.Sprint(v)
					}
					return ""
				}
				id := value("id")
				if id == "" {
					continue
				}
				when := value("createdAt")
				if when == "" {
					when = value("at")
				}
				detail, _ := json.MarshalIndent(record, "", "  ")
				if len(detail) > 16384 {
					detail = detail[:16384]
					for !utf8.Valid(detail) {
						detail = detail[:len(detail)-1]
					}
					detail = append(detail, []byte("\n… Detail truncated at 16 KiB")...)
				}
				at, parseErr := time.Parse(time.RFC3339Nano, when)
				if parseErr == nil {
					oldMin, _ := time.Parse(time.RFC3339Nano, out.Before[trail.name])
					oldMax, _ := time.Parse(time.RFC3339Nano, out.Since[trail.name])
					if oldMin.IsZero() || at.Before(oldMin) {
						out.Before[trail.name] = when
					}
					if oldMax.IsZero() || at.After(oldMax) {
						out.Since[trail.name] = when
					}
				}
				if trail.name == "HTTP" {
					pool := value("poolId")
					row, _ := strconv.ParseInt(strings.TrimPrefix(id, "http_"), 10, 64)
					old, _ := strconv.ParseInt(strings.TrimPrefix(out.After[pool], "http_"), 10, 64)
					if row > old {
						out.After[pool] = id
					}
				}
				parts := []string{}
				for _, key := range []string{"method", "status", "statusCode", "blockedReason", "url", "provider", "event", "type", "decision", "verdict", "reason", "execId"} {
					if v := value(key); v != "" {
						parts = append(parts, v)
					}
				}
				if len(parts) == 0 {
					parts = append(parts, id)
				}
				summary := strings.Join(parts, " · ")
				if len(summary) > 1000 {
					summary = summary[:1000]
				}
				out.Records = append(out.Records, auditRow{ID: trail.name + "/" + value("poolId") + "/" + id + "/" + value("event"), Source: trail.name, Time: when, Order: float64(at.UnixNano()) / 1e9, Summary: summary, Detail: string(detail)})
			}
		}()
	}
	wg.Wait()
	sort.Slice(out.Records, func(i, j int) bool {
		if out.Records[i].Order == out.Records[j].Order {
			return out.Records[i].ID < out.Records[j].ID
		}
		return out.Records[i].Order > out.Records[j].Order
	})
	sort.Strings(out.Missing)
	sort.Strings(out.Limited)
	data, err := json.Marshal(out)
	if len(data) > 6<<20 {
		// Keep every identity/cursor. Shorten details instead of dropping rows
		// and advancing the cursor past entries the UI never received.
		for i := range out.Records {
			if len(out.Records[i].Detail) > 256 {
				detail := out.Records[i].Detail[:256]
				for !utf8.ValidString(detail) {
					detail = detail[:len(detail)-1]
				}
				out.Records[i].Detail = detail + "\n… Detail omitted to fit snapshot; narrow the trail or inspect its recording."
			}
		}
		out.Limited = append(out.Limited, "Detail payload")
		data, err = json.Marshal(out)
	}
	return response{Version: 1, Status: 200, Body: data}, err
}
