package wdttingress

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDiscover(t *testing.T) {
	for _, tc := range []struct {
		name, modern, legacy string
		want                 []string
		bad                  bool
	}{
		{name: "no manager"},
		{name: "empty modern null", modern: `{"version":1,"instances":null}`},
		{name: "empty legacy null", legacy: `{"servers":null}`},
		{name: "legacy implicit standalone", legacy: `{"servers":[{"config":{"enabled":true}}]}`, want: []string{"wdtt0", "wdttraw0"}},
		{name: "legacy explicit standalone", legacy: `{"servers":[{"config":{"wgIface":"wdtt0","rawIface":"wdttraw0"}}]}`, want: []string{"wdtt0", "wdttraw0"}},
		{name: "WG and RAW server only", modern: `{"version":1,"instances":[{"kind":"wdtt-server","enabled":true,"wdttServer":{"wgIface":"opkgtun17","rawIface":"opkgtun18"}},{"kind":"wdtt-client","enabled":true,"wdttClient":{"rawIface":"opkgtun19"}}]}`, want: []string{"opkgtun17", "opkgtun18"}},
		{name: "legacy server", legacy: `{"clients":[{"config":{"rawIface":"opkgtun3"}}],"servers":[{"config":{"enabled":true,"wgIface":"opkgtun7","rawIface":"opkgtun8"}}]}`, want: []string{"opkgtun7", "opkgtun8"}},
		{name: "new store overrides old", modern: `{"version":1,"instances":[]}`, legacy: `{"servers":[{"config":{"wgIface":"opkgtun7","rawIface":"opkgtun8"}}]}`},
		{name: "disabled server pins stay excluded", modern: `{"version":1,"instances":[{"kind":"wdtt-server","enabled":false,"wdttServer":{"wgIface":"opkgtun17","rawIface":"opkgtun18"}}]}`, want: []string{"opkgtun17", "opkgtun18"}},
		{name: "bad JSON must not mean no WDTT", modern: `{"version":1,`, bad: true},
		{name: "unknown schema", modern: `{"version":2,"instances":[]}`, bad: true},
		{name: "missing array", modern: `{"version":1}`, bad: true},
		{name: "missing server config", modern: `{"version":1,"instances":[{"kind":"wdtt-server"}]}`, bad: true},
		{name: "invalid interface", legacy: `{"servers":[{"config":{"wgIface":"opkgtun+","rawIface":"opkgtun8"}}]}`, bad: true},
		{name: "NDMS names are not kernel names", legacy: `{"servers":[{"config":{"wgIface":"OpkgTun17","rawIface":"OpkgTun18"}}]}`, bad: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, body := range map[string]string{"proxy-instances.json": tc.modern, "wdtt.json": tc.legacy} {
				if body != "" {
					if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
						t.Fatal(err)
					}
				}
			}
			got, err := Discover(dir)
			if (err != nil) != tc.bad {
				t.Fatalf("error=%v, want error=%v", err, tc.bad)
			}
			if !tc.bad && !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %v want %v", got, tc.want)
			}
		})
	}
}
