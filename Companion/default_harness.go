package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
)

// A default is project metadata. This never changes a harness or an existing box.
func (b *bridge) setDefaultHarness(ctx context.Context, req request) (response, error) {
	if !b.allowManage || validID(req.ProjectID) != nil || validID(req.HarnessID) != nil {
		return response{}, errors.New("choose a harness on a connected computer before setting its default")
	}
	result, err := b.call(ctx, http.MethodPut, "/projects/"+req.ProjectID+"/harness-configs/"+req.HarnessID+"/default", nil)
	if err != nil {
		return response{}, fmt.Errorf("the default harness may have changed; refresh before retrying: %w", err)
	}
	return result, nil
}
