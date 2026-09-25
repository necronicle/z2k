package edgepick

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"
)

const cacheTTL = 24 * time.Hour

type cacheFile struct {
	Version int       `json:"version"`
	WAN     string    `json:"wan"`
	SavedAt time.Time `json:"saved_at"`
	Results []Result  `json:"results"`
}

// LoadCache returns hints for the same uplink only. Live proof is still needed.
func LoadCache(path, wan string, now time.Time) []Result {
	if wan == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var cache cacheFile
	dec := json.NewDecoder(io.LimitReader(f, 64<<10))
	if err := dec.Decode(&cache); err != nil || cache.Version != 1 || cache.WAN != wan {
		return nil
	}
	if cache.SavedAt.IsZero() || now.Sub(cache.SavedAt) > cacheTTL || cache.SavedAt.Sub(now) > 5*time.Minute {
		return nil
	}
	var result []Result
	for _, r := range cache.Results {
		if r.Step.Transport != "wg" || r.Step.Host == "" || r.Step.Port < 1 || r.Step.Port > 65535 {
			continue
		}
		if r.CheckedAt.IsZero() || now.Sub(r.CheckedAt) > cacheTTL || r.CheckedAt.Sub(now) > 5*time.Minute {
			continue
		}
		result = append(result, r)
	}
	return result
}

// SaveCache writes a versioned, key-free hint file using atomic rename.
func SaveCache(ctx context.Context, path, wan string, results []Result) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var savedAt time.Time
	for _, r := range results {
		if r.CheckedAt.After(savedAt) {
			savedAt = r.CheckedAt
		}
	}
	if savedAt.IsZero() {
		savedAt = time.Now()
	}
	data, err := json.Marshal(cacheFile{Version: 1, WAN: wan, SavedAt: savedAt, Results: results})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".edge-cache-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	if dir, err := os.Open(filepath.Dir(path)); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}
