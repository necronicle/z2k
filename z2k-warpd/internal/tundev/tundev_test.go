package tundev

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestConfigureCommands(t *testing.T) {
	var got []string
	run := func(n string, a ...string) (string, error) {
		got = append(got, n+" "+strings.Join(a, " "))
		return "", nil
	}
	if err := Configure(run, "z2ktun0", "172.16.0.2", 1280); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"ip addr add 172.16.0.2/32 dev z2ktun0",
		"ip link set dev z2ktun0 mtu 1280",
		"ip link set dev z2ktun0 up",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%q", got)
	}
}

func TestConfigureToleratesAddrExists(t *testing.T) {
	run := func(n string, a ...string) (string, error) {
		if a[0] == "addr" {
			return "RTNETLINK answers: File exists", errors.New("exit 2")
		}
		return "", nil
	}
	if err := Configure(run, "z2ktun0", "172.16.0.2", 1280); err != nil {
		t.Fatalf("File exists must not fail: %v", err)
	}
}

func TestConfigureFailsOnOtherError(t *testing.T) {
	run := func(n string, a ...string) (string, error) {
		return "Cannot find device", errors.New("exit 1")
	}
	if err := Configure(run, "z2ktun0", "172.16.0.2", 1280); err == nil {
		t.Fatal("want error")
	}
}

func TestPickNameSkipsExisting(t *testing.T) {
	if n := PickName(func(s string) bool { return s == "z2ktun0" || s == "z2ktun1" }); n != "z2ktun2" {
		t.Fatal(n)
	}
	if n := PickName(func(string) bool { return false }); n != "z2ktun0" {
		t.Fatal(n)
	}
}

func TestTeardown(t *testing.T) {
	var got []string
	run := func(n string, a ...string) (string, error) {
		got = append(got, n+" "+strings.Join(a, " "))
		return "", nil
	}
	if err := Teardown(run, "z2ktun0"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []string{"ip link set dev z2ktun0 down"}) {
		t.Fatalf("%q", got)
	}
}
