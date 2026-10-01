package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Exercise JSON discovery, shipped shell/NDM scripts, and packet decisions
// together. The adapter replaces only Linux tools unavailable on macOS.
func TestWDTTIngressRouting(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	binary := filepath.Join(t.TempDir(), "z2k-warpd")
	build := exec.CommandContext(ctx, filepath.Join(runtime.GOROOT(), "bin", "go"), "build", "-o", binary, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, python, filepath.Join(root, "tests", "warp_scope_test.py"), root)
	cmd.Env = append(os.Environ(), "WARP_SCOPE_BIN="+binary)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("routing: %v\n%s", err, out)
	}
}
