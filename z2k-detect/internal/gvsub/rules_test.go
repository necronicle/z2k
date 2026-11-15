package gvsub

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

type mockFW struct {
	tables map[string][]string // "bin/table/chain" -> rules
	calls  []string
}

func newMockFW() *mockFW {
	return &mockFW{tables: make(map[string][]string)}
}

func (m *mockFW) run(bin string, args ...string) error {
	m.calls = append(m.calls, bin+" "+strings.Join(args, " "))
	// Ожидаем: -w -t <table> <op> <chain> [pos] <spec...>
	if len(args) < 5 || args[0] != "-w" || args[1] != "-t" {
		return fmt.Errorf("unexpected args: %v", args)
	}
	table, op, chain := args[2], args[3], args[4]
	key := bin + "/" + table + "/" + chain
	switch op {
	case "-C":
		spec := strings.Join(args[5:], " ")
		if slices.Contains(m.tables[key], spec) {
			return nil
		}
		return fmt.Errorf("rule not found")
	case "-I":
		if len(args) < 7 {
			return fmt.Errorf("short -I: %v", args)
		}
		spec := strings.Join(args[6:], " ")
		m.tables[key] = append([]string{spec}, m.tables[key]...)
		return nil
	case "-D":
		spec := strings.Join(args[5:], " ")
		cur := m.tables[key]
		idx := slices.Index(cur, spec)
		if idx < 0 {
			return fmt.Errorf("rule not found")
		}
		m.tables[key] = append(cur[:idx], cur[idx+1:]...)
		return nil
	case "-F":
		delete(m.tables, key)
		return nil
	case "-X":
		delete(m.tables, key)
		return nil
	default:
		return fmt.Errorf("unsupported op %s", op)
	}
}

func TestRulesEnsureAndTeardownOutputAndForward(t *testing.T) {
	fw := newMockFW()
	r := IPTables{Queue: "210", Run: fw.run}

	recreated, err := r.Ensure()
	if err != nil {
		t.Fatalf("first Ensure failed: %v", err)
	}
	if !recreated {
		t.Fatal("first Ensure must report recreated=true when inserting missing rules")
	}

	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, chain := range []string{"OUTPUT", "FORWARD"} {
			key := bin + "/mangle/" + chain
			got := fw.tables[key]
			if len(got) != 3 {
				t.Fatalf("%s: expected 3 DNS rules, got %d (%v)", key, len(got), got)
			}
			joined := strings.Join(got, "\n")
			for _, wantSub := range []string{
				"--string googlevideo",
				"--hex-string " + cacheDNSHex,
				"--hex-string |046776743103636f6d00|",
			} {
				if !strings.Contains(joined, wantSub) {
					t.Fatalf("%s missing %q in %v", key, wantSub, got)
				}
			}
		}
	}
	for _, c := range fw.calls {
		if strings.Contains(c, "-t nat") || strings.Contains(c, "DNAT") {
			t.Fatalf("unexpected DNAT/nat rule in Ensure: %s", c)
		}
	}

	// Повторный Ensure идемпотентен: ни одного нового правила не вставляется.
	recreated, err = r.Ensure()
	if err != nil {
		t.Fatalf("second Ensure failed: %v", err)
	}
	if recreated {
		t.Fatal("second Ensure must be idempotent (recreated=false)")
	}

	// Потеря одного правила в FORWARD (например, при перестройке таблиц роутером)
	// лечится точечно без дублирования OUTPUT.
	fw.tables["iptables/mangle/FORWARD"] = fw.tables["iptables/mangle/FORWARD"][1:]
	recreated, err = r.Ensure()
	if err != nil || !recreated {
		t.Fatalf("repair Ensure: recreated=%v err=%v", recreated, err)
	}
	if len(fw.tables["iptables/mangle/FORWARD"]) != 3 || len(fw.tables["iptables/mangle/OUTPUT"]) != 3 {
		t.Fatalf("unexpected rule counts after repair: fwd=%d out=%d",
			len(fw.tables["iptables/mangle/FORWARD"]), len(fw.tables["iptables/mangle/OUTPUT"]))
	}

	// Добавим устаревшую форму (без --icase) в FORWARD и проверим, что Teardown
	// вычищает обе цепочки (OUTPUT и FORWARD) и в актуальной, и в legacy-форме.
	legacyRule := "! -o lo -p udp --sport 53 -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"
	fw.tables["iptables/mangle/FORWARD"] = append(fw.tables["iptables/mangle/FORWARD"], legacyRule)
	fw.tables["ip6tables/mangle/OUTPUT"] = append(fw.tables["ip6tables/mangle/OUTPUT"], legacyRule)
	fw.tables["iptables/filter/FORWARD"] = []string{"-j Z2K_GVSUB_Q"}

	r.Teardown()
	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, chain := range []string{"OUTPUT", "FORWARD"} {
			key := bin + "/mangle/" + chain
			if len(fw.tables[key]) != 0 {
				t.Fatalf("Teardown left rules in %s: %v", key, fw.tables[key])
			}
		}
	}
	if len(fw.tables["iptables/filter/FORWARD"]) != 0 {
		t.Fatalf("Teardown left legacy hook in filter/FORWARD: %v", fw.tables["iptables/filter/FORWARD"])
	}
}

func TestRulesNoV6SkipsIP6Tables(t *testing.T) {
	fw := newMockFW()
	r := IPTables{Queue: "210", NoV6: true, Run: fw.run}
	if _, err := r.Ensure(); err != nil {
		t.Fatal(err)
	}
	r.Teardown()
	for _, c := range fw.calls {
		if strings.HasPrefix(c, "ip6tables ") {
			t.Fatalf("NoV6 must not invoke ip6tables, got: %s", c)
		}
	}
}
