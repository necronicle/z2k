// Package sockmark — метка SO_MARK, по которой правила NFQUEUE пропускают
// пакет мимо нашего же десинка. Любой зонд обязан ходить помеченным: иначе он
// меряет не коробку провайдера, а наш обход поверх неё.
//
// Одно место на все зонды: раньше константа и установка метки жили
// четырьмя копиями в classify, quicprobe, tcp16 и voiceprobe, и правка в
// одной молча расходилась с остальными.
//
// Для UDP у метки есть ВТОРАЯ роль, которой нет у TCP: правило
// z2k_udp_masquerade_fix в таблице nat заворачивает помеченные UDP-пакеты в
// MASQUERADE. Это не мешает замеру — исходный порт сохраняется, — но
// означает, что помеченная датаграмма проходит другой путь, чем непомеченная,
// и сравнивать их между собой нельзя.
package sockmark

import (
	"strconv"
	"strings"
)

// Bypass — значение метки; совпадает с маской обхода в правилах z2k.
const Bypass = 0x40000000

// ParsePolicyMark разбирает вывод `iptables -t mangle -S POSTROUTING` и `-S Z2K_POL`,
// определяя активную метку политики режима включения (POLICY_EXCLUDE=0), чтобы
// сокеты контура C2 не получали CONNMARK-исключение 0x20000000 и попадали в nfqws2.
// Возвращает (0, false), если активной политики включения нет (например, POLICY_EXCLUDE=1).
func ParsePolicyMark(postroutingOut, z2kPolOut string) (uint32, bool) {
	// Сначала проверяем выделенную цепочку Z2K_POL, но только если POSTROUTING реально прыгает в неё.
	if strings.TrimSpace(z2kPolOut) != "" && hasChainJump(postroutingOut, "POSTROUTING", "Z2K_POL") {
		if m, ok := parseIncludeRuleLines(z2kPolOut, "Z2K_POL"); ok {
			return m, true
		}
	}
	// Запасной разбор прямого правила в POSTROUTING (устаревший формат без Z2K_POL).
	return parseIncludeRuleLines(postroutingOut, "POSTROUTING")
}

func hasChainJump(out, chain, target string) bool {
	for _, raw := range strings.Split(out, "\n") {
		fields := strings.Fields(raw)
		if len(fields) < 4 || fields[0] != "-A" || fields[1] != chain {
			continue
		}
		for i := 2; i+1 < len(fields); i++ {
			if fields[i] == "-j" && fields[i+1] == target {
				return true
			}
		}
	}
	return false
}

func parseIncludeRuleLines(out, chain string) (uint32, bool) {
	for _, raw := range strings.Split(out, "\n") {
		fields := strings.Fields(raw)
		if len(fields) < 4 {
			continue
		}
		if fields[0] != "-A" || fields[1] != chain {
			continue
		}
		if m, ok := parseNegatedPolicyMarkRule(fields[2:]); ok {
			return m, true
		}
	}
	return 0, false
}

func parseNegatedPolicyMarkRule(tokens []string) (uint32, bool) {
	var hasSetXmark, hasExcludeMask, hasNegMark bool
	var markSpec string

	for i := 0; i < len(tokens); i++ {
		tok := tokens[i]
		switch tok {
		case "-j":
			if i+1 < len(tokens) && tokens[i+1] == "CONNMARK" {
				i++
			}
		case "--set-xmark":
			hasSetXmark = true
			if i+1 < len(tokens) {
				v := strings.ToLower(tokens[i+1])
				if strings.HasPrefix(v, "0x20000000/") || v == "0x20000000" {
					hasExcludeMask = true
				}
				i++
			}
		case "!":
			// Старые iptables печатают "! -m mark --mark ...", новые "-m mark ! --mark ...".
			if i+3 < len(tokens) && tokens[i+1] == "-m" && tokens[i+2] == "mark" && tokens[i+3] == "--mark" {
				hasNegMark = true
				if i+4 < len(tokens) {
					markSpec = tokens[i+4]
					i += 4
				}
			}
		case "-m":
			if i+1 < len(tokens) && tokens[i+1] == "mark" {
				if i+3 < len(tokens) && tokens[i+2] == "!" && tokens[i+3] == "--mark" {
					hasNegMark = true
					if i+4 < len(tokens) {
						markSpec = tokens[i+4]
						i += 4
					}
				}
			}
		}
	}

	if !hasSetXmark || !hasExcludeMask || !hasNegMark || markSpec == "" {
		return 0, false
	}

	parts := strings.SplitN(markSpec, "/", 2)
	val, err := parseHexOrDecUint32(parts[0])
	if err != nil {
		return 0, false
	}
	if len(parts) == 2 {
		mask, err := parseHexOrDecUint32(parts[1])
		if err != nil {
			return 0, false
		}
		val &= mask
	}
	if val == 0 {
		return 0, false
	}
	return val, true
}

func parseHexOrDecUint32(s string) (uint32, error) {
	u, err := strconv.ParseUint(strings.TrimSpace(s), 0, 32)
	if err != nil {
		return 0, err
	}
	return uint32(u), nil
}
