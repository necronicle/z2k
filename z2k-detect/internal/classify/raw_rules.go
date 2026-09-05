package classify

// Разбор правил подавления ядерного RST. Вынесен из платформенного файла: это
// чистая работа со строкой, и она обязана проверяться на любой машине, а не
// только там, где есть iptables.

import (
	"strconv"
	"strings"
)

// parseStaleRSTRule — наше ли это правило и на каком порту.
//
// Форма нормализована самим iptables (проверено на роутере, v1.4.21):
//
//	-A OUTPUT -p tcp -m tcp --sport N --tcp-flags RST RST -j DROP
//
// Сверяем её целиком и порт из нашего диапазона: чужие правила с флагом RST
// трогать нельзя, они не наши и снимать их мы не вправе.
const (
	staleRulePrefix = "-A OUTPUT -p tcp -m tcp --sport "
	staleRuleSuffix = " --tcp-flags RST RST -j DROP"
)

func parseStaleRSTRule(line string) (int, bool) {
	line = strings.TrimSpace(line)
	// Сравниваем форму ЦЕЛИКОМ, началом и концом. Через Sscanf это уже
	// прострелило: он возвращает частичный разбор при несовпадении хвоста, и
	// правило с чужим действием (-j ACCEPT) принималось за своё.
	if !strings.HasPrefix(line, staleRulePrefix) || !strings.HasSuffix(line, staleRuleSuffix) {
		return 0, false
	}
	mid := line[len(staleRulePrefix) : len(line)-len(staleRuleSuffix)]
	port, err := strconv.Atoi(mid)
	if err != nil {
		return 0, false
	}
	// Только наш диапазон: чужие правила с флагом RST снимать мы не вправе.
	if port < 30000 || port > 54999 {
		return 0, false
	}
	return port, true
}
