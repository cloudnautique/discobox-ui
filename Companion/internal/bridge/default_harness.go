package bridge

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// A default is project metadata. This never changes a harness or an existing box.
func (b *Bridge) setDefaultHarness(ctx context.Context, req wire.Request) (wire.Response, error) {
	if ValidID(req.ProjectID) != nil || ValidID(req.HarnessID) != nil {
		return wire.Response{}, errors.New("choose a harness on a connected computer before setting its default")
	}
	result, err := b.Call(ctx, http.MethodPut, "/projects/"+req.ProjectID+"/harness-configs/"+req.HarnessID+"/default", nil)
	if err != nil {
		return wire.Response{}, fmt.Errorf("the default harness may have changed; refresh before retrying: %w", err)
	}
	return result, nil
}
