package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// Read the same stored pool reports used by `admin pool resources`. These
// requests never trigger disk walks, probe a box, or start a pool.
func (b *Bridge) poolOperation(ctx context.Context, req wire.Request) (wire.Response, error) {
	if err := ValidID(req.ProjectID); err != nil {
		return wire.Response{}, err
	}
	base := "/projects/" + req.ProjectID
	if req.Operation == "clearPoolCache" {
		if err := ValidID(req.PoolID); err != nil {
			return wire.Response{}, err
		}
		// One request only: a lost response may still mean cleanup is running.
		return b.Call(ctx, "POST", base+"/pools/"+req.PoolID+"/clear-cache", nil)
	}
	pools, err := b.Call(ctx, "GET", base+"/pools", nil)
	if err != nil || pools.Status != 200 {
		return pools, err
	}
	project, err := b.Call(ctx, "GET", base, nil)
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
		return wire.Response{}, errors.New("invalid pool inventory response")
	}
	data, err := json.Marshal(struct {
		Pools         json.RawMessage `json:"pools"`
		DefaultPoolID string          `json:"defaultPoolId"`
	}{list.Pools, placement.DefaultPoolID})
	return wire.Response{Version: wire.ProtocolVersion, Status: 200, Body: data}, err
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
