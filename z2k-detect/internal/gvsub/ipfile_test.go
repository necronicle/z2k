package gvsub

import (
	"net/netip"
	"os"
	"testing"
)

func TestWriteIPsSentinels(t *testing.T) {
	for _, populated := range []bool{false, true} {
		t.Run(map[bool]string{false: "empty", true: "addresses"}[populated], func(t *testing.T) {
			s := &Service{IPFile: t.TempDir() + "/ips"}
			want := "0.0.0.0/32\n::/128\n"
			if populated {
				s.known = map[netip.Addr]*entry{netip.MustParseAddr("1.1.1.1"): {}, netip.MustParseAddr("2606:4700::1111"): {}}
				want += "1.1.1.1\n2606:4700::1111\n"
			}
			for _, damage := range []string{"initial", "remove", "truncate"} {
				switch damage {
				case "remove":
					if err := os.Remove(s.IPFile); err != nil {
						t.Fatal(err)
					}
				case "truncate":
					if err := os.WriteFile(s.IPFile, nil, 0644); err != nil {
						t.Fatal(err)
					}
				}
				s.writeIPs()
				got, err := os.ReadFile(s.IPFile)
				if err != nil || string(got) != want {
					t.Fatalf("%s: got %q, err %v, want %q", damage, got, err, want)
				}
			}
		})
	}
}
