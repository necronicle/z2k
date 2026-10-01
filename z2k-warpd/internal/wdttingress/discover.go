// Package wdttingress reads AWG Manager's WDTT server interface assignments.
// Schema reference: hoaxisr/awg-manager at 61b489e145386846bae6840823d7d52294854a7c,
// internal/proxyrt/instancestore/{record,store,seed}.go. No upstream code is used.
package wdttingress

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

const maxConfig = 4 << 20

var kernelName = regexp.MustCompile(`^opkgtun[0-9]+$`)

type server struct {
	WG      string `json:"wgIface"`
	Raw     string `json:"rawIface"`
	NDMS    string `json:"ndmsIface"`
	RawNDMS string `json:"rawNdmsIface"`
}

// Discover returns only server ingress pins, never client VPN exits. Disabled
// server records still own their pins, so a teardown race cannot treat them as LAN.
// A present modern store supersedes legacy data; never resurrect migrated pins.
func Discover(dir string) ([]string, error) {
	var modern struct {
		Version   int             `json:"version"`
		Instances json.RawMessage `json:"instances"`
	}
	var servers []*server
	legacy := false
	err := read(filepath.Join(dir, "proxy-instances.json"), &modern)
	if err == nil {
		if modern.Version != 1 || modern.Instances == nil {
			return nil, errors.New("unsupported AWG Manager instance schema")
		}
		var records []struct {
			Kind   string  `json:"kind"`
			Server *server `json:"wdttServer"`
		}
		if json.Unmarshal(modern.Instances, &records) != nil {
			return nil, errors.New("invalid AWG Manager instances")
		}
		for _, r := range records {
			if r.Kind == "wdtt-server" {
				servers = append(servers, r.Server)
			}
		}
	} else if errors.Is(err, os.ErrNotExist) {
		var old struct {
			Servers json.RawMessage `json:"servers"`
		}
		if err = read(filepath.Join(dir, "wdtt.json"), &old); errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if old.Servers == nil {
			return nil, errors.New("unsupported AWG Manager WDTT schema")
		}
		legacy = true
		var records []struct {
			Config *server `json:"config"`
		}
		if json.Unmarshal(old.Servers, &records) != nil {
			return nil, errors.New("invalid AWG Manager servers")
		}
		for _, r := range records {
			servers = append(servers, r.Config)
		}
	} else {
		return nil, err
	}
	var result []string
	seen := map[string]bool{}
	for _, s := range servers {
		if s == nil {
			return nil, errors.New("missing WDTT server configuration")
		}
		if legacy {
			if s.WG == "" && s.NDMS == "" {
				s.WG = "wdtt0"
			}
			if s.Raw == "" && s.RawNDMS == "" {
				s.Raw = "wdttraw0"
			}
		}
		for _, name := range []string{s.WG, s.Raw} {
			if len(name) > 15 || (!kernelName.MatchString(name) && !(legacy && (name == "wdtt0" || name == "wdttraw0"))) {
				return nil, errors.New("invalid WDTT server kernel interface")
			}
			if !seen[name] {
				result = append(result, name)
				seen[name] = true
			}
		}
	}
	sort.Strings(result)
	return result, nil
}

func read(path string, out any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxConfig+1))
	if err != nil {
		return err
	}
	if len(b) > maxConfig {
		return errors.New("AWG Manager configuration too large")
	}
	// Never echo content: these files may also contain passwords and keys.
	if err = json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("invalid AWG Manager JSON in %s", filepath.Base(path))
	}
	return nil
}
