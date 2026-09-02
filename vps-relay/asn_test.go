package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

const asnFixture = "1.0.0.0\t1.0.0.255\t13335\tUS\tCLOUDFLARENET\n" +
	"46.146.0.0\t46.146.255.255\t35807\tRU\tAS-SKYNET-SPB\n" +
	"88.87.64.0\t88.87.95.255\t39435\tRU\tEVOLGOGRAD-AS\n"

func TestASNTable_Lookup(t *testing.T) {
	p := filepath.Join(t.TempDir(), "ip2asn-v4.tsv")
	if err := os.WriteFile(p, []byte(asnFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	tab, err := loadASNTable(p)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]uint32{
		"46.146.27.195": 35807,
		"88.87.93.11":   39435,
		"88.87.96.1":    0, // за верхней границей
		"9.9.9.9":       0,
		"1.0.0.7":       13335,
	}
	for ip, want := range cases {
		if got := tab.lookup(net.ParseIP(ip)); got != want {
			t.Fatalf("%s: asn %d, ожидалось %d", ip, got, want)
		}
	}
}

func TestASNLookup_DisabledReturnsZero(t *testing.T) {
	asnTab.Store(nil)
	if got := asnLookup("46.146.27.195"); got != 0 {
		t.Fatalf("без таблицы ожидался 0, получено %d", got)
	}
}

func TestASNTable_RejectsGarbage(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bad.tsv")
	if err := os.WriteFile(p, []byte("not a table\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadASNTable(p); err == nil {
		t.Fatal("мусор принят как таблица")
	}
}
