package main

import (
	"flag"
	"testing"
)

func TestParseAdditionalIPv4Targets(t *testing.T) {
	got, err := parseAdditionalIPv4Targets([]string{"74.125.131.104", "74.125.131.105"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "74.125.131.104" || got[1] != "74.125.131.105" {
		t.Fatalf("targets = %#v", got)
	}
}

func TestParseAdditionalIPv4TargetsRejectsNonIPv4(t *testing.T) {
	if _, err := parseAdditionalIPv4Targets([]string{"2001:db8::1"}); err == nil {
		t.Fatal("IPv6 target accepted for IPv4 multi-edge validation")
	}
}

func TestAlsoTestIPFlagCanBeRepeated(t *testing.T) {
	fs := flag.NewFlagSet("classify", flag.ContinueOnError)
	var raw repeatedStringFlag
	fs.Var(&raw, "also-test-ip", "")
	if err := fs.Parse([]string{"-also-test-ip", "74.125.131.104", "-also-test-ip", "74.125.131.105"}); err != nil {
		t.Fatal(err)
	}
	got, err := parseAdditionalIPv4Targets(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("repeated targets = %#v", got)
	}
}
