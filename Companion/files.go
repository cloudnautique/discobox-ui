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
	"path"
	"path/filepath"
	"strings"
	"time"
)

type fileStat struct {
	Path    string `json:"path"`
	Name    string `json:"name"`
	Type    string `json:"type"`
	Size    int64  `json:"size"`
	Version string `json:"version"`
}
type fileList struct {
	Path    string     `json:"path"`
	Entries []fileStat `json:"entries"`
}
type transferProgress struct {
	bytes int64
	last  time.Time
}

func (p *transferProgress) Write(data []byte) (int, error) {
	p.bytes += int64(len(data))
	if time.Since(p.last) > 100*time.Millisecond {
		fmt.Fprintln(os.Stderr, p.bytes)
		p.last = time.Now()
	}
	return len(data), nil
}
func (b *bridge) fileOperation(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.SandboxID) != nil {
		return response{}, errors.New("invalid box")
	}
	if err := b.requireRunningBox(ctx, req); err != nil {
		return response{}, err
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/files"
	if req.Operation == "files" {
		return b.call(ctx, "GET", base+"/list?path="+url.QueryEscape(req.RemotePath), nil)
	}
	if !b.allowManage {
		return response{}, errors.New("file transfers require explicit permission")
	}
	if req.LocalPath == "" || req.RemotePath == "" {
		return response{}, errors.New("missing transfer path")
	}
	progress := &transferProgress{}
	var err error
	switch req.Operation {
	case "upload":
		err = b.uploadTree(ctx, base, req.LocalPath, req.RemotePath, req.Action == "replace", progress, 0)
	case "download":
		// Work in a new sibling staging directory. Neither remote names nor symlinks
		// can redirect writes outside it. Publish without replacing any local path.
		local := filepath.Clean(req.LocalPath)
		stage, e := os.MkdirTemp(filepath.Dir(local), ".discobox-transfer-")
		if e != nil {
			return response{}, e
		}
		defer os.RemoveAll(stage)
		staged := filepath.Join(stage, "content")
		err = b.downloadTree(ctx, base, req.RemotePath, staged, progress, 0)
		if err == nil {
			err = publishDownload(staged, local)
		}
	default:
		err = errors.New("unknown transfer")
	}
	fmt.Fprintln(os.Stderr, progress.bytes)
	if err != nil {
		return response{}, err
	}
	return response{Version: 1, Status: 200, Body: []byte(`{}`)}, nil
}
func (b *bridge) statFile(ctx context.Context, base, remote string) (fileStat, int, error) {
	r, err := b.call(ctx, "GET", base+"/stat?path="+url.QueryEscape(remote), nil)
	if err != nil {
		return fileStat{}, 0, err
	}
	var s fileStat
	if r.Status != 200 {
		return s, r.Status, nil
	}
	err = json.Unmarshal(r.Body, &s)
	return s, 200, err
}
func safeChild(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\\\x00")
}
func (b *bridge) uploadTree(ctx context.Context, base, local, remote string, replace bool, p *transferProgress, depth int) error {
	if depth > 64 {
		return errors.New("directory nesting limit reached")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := os.Lstat(local)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("symlink transfer is not supported: %s", local)
	}
	if info.IsDir() {
		body, _ := json.Marshal(map[string]any{"path": remote, "parents": true})
		r, err := b.call(ctx, "POST", base+"/mkdir", body)
		if err != nil {
			return err
		}
		if r.Status < 200 || r.Status >= 300 {
			return fmt.Errorf("create directory %s: HTTP %d", remote, r.Status)
		}
		entries, err := os.ReadDir(local)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if !safeChild(entry.Name()) {
				return errors.New("invalid file name")
			}
			if err := b.uploadTree(ctx, base, filepath.Join(local, entry.Name()), path.Join(remote, entry.Name()), replace, p, depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("unsupported file: %s", local)
	}
	query := url.Values{"path": {remote}, "ifExists": {"fail"}}
	if replace {
		s, status, err := b.statFile(ctx, base, remote)
		if err != nil {
			return err
		}
		if status == 200 {
			if s.Type != "file" {
				return errors.New("replacement target is not a regular file")
			}
			query.Set("ifExists", "replace")
			query.Set("ifVersion", s.Version)
		} else if status != 404 {
			return fmt.Errorf("stat target: HTTP %d", status)
		}
	}
	file, err := os.Open(local)
	if err != nil {
		return err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(info, opened) {
		return errors.New("local file changed before upload")
	}
	request, err := http.NewRequestWithContext(ctx, "PUT", b.base+base+"/content?"+query.Encode(), io.TeeReader(file, p))
	if err != nil {
		return err
	}
	request.ContentLength = info.Size()
	request.Header.Set("Content-Type", "application/octet-stream")
	result, err := b.client.Do(request)
	if err != nil {
		return err
	}
	defer result.Body.Close()
	if result.StatusCode < 200 || result.StatusCode >= 300 {
		return fmt.Errorf("upload %s: HTTP %d (existing or changed files are not overwritten without confirmation)", remote, result.StatusCode)
	}
	return nil
}
func (b *bridge) downloadTree(ctx context.Context, base, remote, local string, p *transferProgress, depth int) error {
	if depth > 64 {
		return errors.New("directory nesting limit reached")
	}
	s, status, err := b.statFile(ctx, base, remote)
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("stat %s: HTTP %d", remote, status)
	}
	if s.Type == "directory" {
		if err := os.Mkdir(local, 0700); err != nil {
			return err
		}
		result, err := b.call(ctx, "GET", base+"/list?path="+url.QueryEscape(remote), nil)
		if err != nil {
			return err
		}
		if result.Status != 200 {
			return fmt.Errorf("list directory: HTTP %d", result.Status)
		}
		var list fileList
		if err := json.Unmarshal(result.Body, &list); err != nil {
			return err
		}
		for _, entry := range list.Entries {
			if !safeChild(entry.Name) {
				return errors.New("unsafe remote file name")
			}
			if err := b.downloadTree(ctx, base, path.Join(remote, entry.Name), filepath.Join(local, entry.Name), p, depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if s.Type != "file" {
		return errors.New("symlinks and special files cannot be downloaded")
	}
	request, err := http.NewRequestWithContext(ctx, "GET", b.base+base+"/content?path="+url.QueryEscape(remote), nil)
	if err != nil {
		return err
	}
	result, err := b.client.Do(request)
	if err != nil {
		return err
	}
	defer result.Body.Close()
	if result.StatusCode != 200 {
		return fmt.Errorf("download: HTTP %d", result.StatusCode)
	}
	file, err := os.OpenFile(local, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	count, err := io.Copy(file, io.TeeReader(result.Body, p))
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	after, status, err := b.statFile(ctx, base, remote)
	if err != nil {
		return err
	}
	if status != 200 || after.Version != s.Version || count != s.Size {
		return errors.New("remote file changed during download; partial copy discarded")
	}
	return nil
}
