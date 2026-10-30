package main

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// Read the same stored pool reports used by `admin pool resources`. These
// requests never trigger disk walks, probe a box, or start a pool.
func (b *bridge) poolOperation(ctx context.Context, req request) (response, error) {
	if err := validID(req.ProjectID); err != nil {
		return response{}, err
	}
	base := "/projects/" + req.ProjectID
	if req.Operation == "clearPoolCache" {
		if !b.allowManage {
			return response{}, errors.New("pool cache cleanup requires explicit permission")
		}
		if err := validID(req.PoolID); err != nil {
			return response{}, err
		}
		// One request only: a lost response may still mean cleanup is running.
		return b.call(ctx, "POST", base+"/pools/"+req.PoolID+"/clear-cache", nil)
	}
	pools, err := b.call(ctx, "GET", base+"/pools", nil)
	if err != nil || pools.Status != 200 {
		return pools, err
	}
	project, err := b.call(ctx, "GET", base, nil)
	if err != nil || project.Status != 200 {
		return project, err
	}
	var list struct {
		Pools json.RawMessage `json:"pools"`
	}
	var placement struct {
		DefaultPoolID string `json:"defaultPoolId"`
	}
	if json.Unmarshal(pools.Body, &list) != nil || len(list.Pools) == 0 || json.Unmarshal(project.Body, &placement) != nil {
		return response{}, errors.New("invalid pool inventory response")
	}
	data, err := json.Marshal(struct {
		Pools         json.RawMessage `json:"pools"`
		DefaultPoolID string          `json:"defaultPoolId"`
	}{list.Pools, placement.DefaultPoolID})
	return response{Version: 1, Status: 200, Body: data}, err
}

// A zero-valued/missing/stale report is not evidence of a full disk. Only the
// reported data filesystem is checked: cache is a separate mount on VM pools
// and existing agents do not report its available space.
func reportedDataDiskFull(raw json.RawMessage, now time.Time) bool {
	var report struct {
		ReportedAt time.Time `json:"reportedAt"`
		Storage    struct {
			Filesystem struct {
				TotalBytes int64  `json:"totalBytes"`
				FreeBytes  *int64 `json:"freeBytes"`
			} `json:"filesystem"`
		} `json:"storage"`
	}
	if json.Unmarshal(raw, &report) != nil {
		return false
	}
	age := now.Sub(report.ReportedAt)
	fs := report.Storage.Filesystem
	return age >= -30*time.Second && age <= 90*time.Second && fs.TotalBytes > 0 && fs.FreeBytes != nil && *fs.FreeBytes == 0
}
