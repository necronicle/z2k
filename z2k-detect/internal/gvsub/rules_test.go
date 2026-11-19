package gvsub

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

type mockFW struct {
	tables   map[string][]string // "bin/table/chain" -> rules
	calls    []string
	failWhen func(bin, table, op, chain, spec string) error
}

func newMockFW() *mockFW {
	return &mockFW{tables: make(map[string][]string)}
}

func (m *mockFW) run(bin string, args ...string) error {
	m.calls = append(m.calls, bin+" "+strings.Join(args, " "))
	// Ожидаем: -w -t <table> <op> <chain> [pos] <spec...>
	if len(args) < 5 || args[0] != "-w" || args[1] != "-t" {
		return fmt.Errorf("неожиданные аргументы: %v", args)
	}
	table, op, chain := args[2], args[3], args[4]
	key := bin + "/" + table + "/" + chain
	switch op {
	case "-C":
		spec := strings.Join(args[5:], " ")
		if m.failWhen != nil {
			if err := m.failWhen(bin, table, op, chain, spec); err != nil {
				return err
			}
		}
		if slices.Contains(m.tables[key], spec) {
			return nil
		}
		return fmt.Errorf("правило не найдено")
	case "-I":
		if len(args) < 7 {
			return fmt.Errorf("короткий -I: %v", args)
		}
		spec := strings.Join(args[6:], " ")
		if m.failWhen != nil {
			if err := m.failWhen(bin, table, op, chain, spec); err != nil {
				return err
			}
		}
		m.tables[key] = append([]string{spec}, m.tables[key]...)
		return nil
	case "-D":
		spec := strings.Join(args[5:], " ")
		cur := m.tables[key]
		idx := slices.Index(cur, spec)
		if idx < 0 {
			return fmt.Errorf("правило не найдено")
		}
		m.tables[key] = append(cur[:idx], cur[idx+1:]...)
		return nil
	case "-F", "-X":
		delete(m.tables, key)
		return nil
	default:
		return fmt.Errorf("неизвестная операция %s", op)
	}
}

func TestRulesEnsureAndTeardownOutputAndForward(t *testing.T) {
	fw := newMockFW()
	r := IPTables{Run: fw.run} // пустой Queue должен использовать "210" по умолчанию

	recreated, err := r.Ensure()
	if err != nil {
		t.Fatalf("первый Ensure вернул ошибку: %v", err)
	}
	if !recreated {
		t.Fatal("первый Ensure обязан вернуть recreated=true при вставке отсутствующих правил")
	}

	wantOutput := []string{
		"! -o lo -p udp --sport 53 -m string --algo bm --icase --hex-string |046776743103636f6d00| -j NFQUEUE --queue-num 210 --queue-bypass",
		"! -o lo -p udp --sport 53 -m string --algo bm --icase --hex-string " + cacheDNSHex + " -j NFQUEUE --queue-num 210 --queue-bypass",
		"! -o lo -p udp --sport 53 -m string --algo bm --icase --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass",
	}
	wantForward := []string{
		"-o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --icase --hex-string |046776743103636f6d00| -j NFQUEUE --queue-num 210 --queue-bypass",
		"-o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --icase --hex-string " + cacheDNSHex + " -j NFQUEUE --queue-num 210 --queue-bypass",
		"-o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --icase --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass",
	}

	for _, bin := range []string{"iptables", "ip6tables"} {
		outKey := bin + "/mangle/OUTPUT"
		if !slices.Equal(fw.tables[outKey], wantOutput) {
			t.Fatalf("%s:\nполучено: %v\nждали:    %v", outKey, fw.tables[outKey], wantOutput)
		}
		for _, rule := range fw.tables[outKey] {
			if strings.Contains(rule, "conntrack") || strings.Contains(rule, "ESTABLISHED") {
				t.Fatalf("%s не должен содержать conntrack: %s", outKey, rule)
			}
		}
		fwdKey := bin + "/mangle/FORWARD"
		if !slices.Equal(fw.tables[fwdKey], wantForward) {
			t.Fatalf("%s:\nполучено: %v\nждали:    %v", fwdKey, fw.tables[fwdKey], wantForward)
		}
		for _, rule := range fw.tables[fwdKey] {
			if !strings.HasPrefix(rule, "-o br+ ") || strings.Contains(rule, "! -o lo") {
				t.Fatalf("%s должен ограничивать выходной интерфейс локальными мостами (-o br+): %s", fwdKey, rule)
			}
		}
	}
	for _, c := range fw.calls {
		if strings.Contains(c, "-t nat") || strings.Contains(c, "DNAT") || strings.Contains(c, "443") {
			t.Fatalf("неожиданное правило в Ensure: %s", c)
		}
	}

	// Повторный Ensure идемпотентен: ни одного нового правила не вставляется.
	callsBefore := len(fw.calls)
	recreated, err = r.Ensure()
	if err != nil {
		t.Fatalf("повторный Ensure вернул ошибку: %v", err)
	}
	if recreated {
		t.Fatal("повторный Ensure обязан быть идемпотентным (recreated=false)")
	}
	for _, c := range fw.calls[callsBefore:] {
		if strings.Contains(c, " -I ") {
			t.Fatalf("повторный Ensure вставил дубль: %s", c)
		}
	}

	// Потеря одного правила в FORWARD (например, при перестройке таблиц роутером)
	// лечится точечно без дублирования OUTPUT.
	fw.tables["iptables/mangle/FORWARD"] = fw.tables["iptables/mangle/FORWARD"][1:]
	recreated, err = r.Ensure()
	if err != nil || !recreated {
		t.Fatalf("ремонт Ensure: recreated=%v err=%v", recreated, err)
	}
	if len(fw.tables["iptables/mangle/FORWARD"]) != 3 || len(fw.tables["iptables/mangle/OUTPUT"]) != 3 {
		t.Fatalf("неожиданное число правил после ремонта: fwd=%d out=%d",
			len(fw.tables["iptables/mangle/FORWARD"]), len(fw.tables["iptables/mangle/OUTPUT"]))
	}

	// Добавим устаревшие формы без --icase и проверим, что Teardown вычищает обе цепочки.
	legacyOut := "! -o lo -p udp --sport 53 -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"
	legacyFwd := "-o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"
	fw.tables["ip6tables/mangle/OUTPUT"] = append(fw.tables["ip6tables/mangle/OUTPUT"], legacyOut)
	fw.tables["iptables/mangle/FORWARD"] = append(fw.tables["iptables/mangle/FORWARD"], legacyFwd)
	fw.tables["iptables/filter/FORWARD"] = []string{"-j Z2K_GVSUB_Q"}

	r.Teardown()
	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, chain := range []string{"OUTPUT", "FORWARD"} {
			key := bin + "/mangle/" + chain
			if len(fw.tables[key]) != 0 {
				t.Fatalf("Teardown оставил правила в %s: %v", key, fw.tables[key])
			}
		}
	}
	if len(fw.tables["iptables/filter/FORWARD"]) != 0 {
		t.Fatalf("Teardown оставил устаревший крючок в filter/FORWARD: %v", fw.tables["iptables/filter/FORWARD"])
	}
}

func TestRulesNoV6AndPartialError(t *testing.T) {
	fw := newMockFW()
	r := IPTables{Queue: "215", NoV6: true, Run: fw.run}
	if recreated, err := r.Ensure(); err != nil || !recreated {
		t.Fatalf("Ensure(NoV6): recreated=%v err=%v", recreated, err)
	}
	if len(fw.tables["iptables/mangle/OUTPUT"]) != 3 || len(fw.tables["iptables/mangle/FORWARD"]) != 3 {
		t.Fatalf("ожидалось по 3 правила в OUTPUT и FORWARD: %v", fw.tables)
	}
	r.Teardown()
	for _, c := range fw.calls {
		if strings.HasPrefix(c, "ip6tables ") {
			t.Fatalf("при NoV6 не должен вызываться ip6tables, получено: %s", c)
		}
	}

	// Частичная ошибка вставки в FORWARD возвращает firstErr и recreated=true,
	// а полный отказ вставки — recreated=false.
	fw2 := newMockFW()
	fw2.failWhen = func(_, _, op, chain, _ string) error {
		if op == "-I" && chain == "FORWARD" {
			return fmt.Errorf("нет xt_conntrack")
		}
		return nil
	}
	recreated, err := IPTables{Queue: "210", NoV6: true, Run: fw2.run}.Ensure()
	if !recreated || err == nil {
		t.Fatalf("ожидались recreated=true и ошибка при отказе FORWARD, получено recreated=%v err=%v", recreated, err)
	}

	fw3 := newMockFW()
	fw3.failWhen = func(_, _, op, _, _ string) error {
		if op == "-I" {
			return fmt.Errorf("отказ вставки")
		}
		return nil
	}
	recreated, err = IPTables{Queue: "210", NoV6: true, Run: fw3.run}.Ensure()
	if recreated || err == nil {
		t.Fatalf("ожидались recreated=false и ошибка при полном отказе, получено recreated=%v err=%v", recreated, err)
	}
}
