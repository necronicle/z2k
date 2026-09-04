//go:build linux

package quicprobe

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Сырой путь отправки собирается только под Linux, а значит на маке он не
// исполняется ни разу — ни в разработке, ни в CI. Именно так уже горели раньше:
// зелёно на маке, красно на живой системе. Поэтому здесь настоящая отправка
// фрагментов настоящему собеседнику, пусть и по петле.
//
// Тест проверяет всю цепочку разом: открылся сырой сокет, заголовок IP собран
// верно, ядро собрало фрагменты обратно, контрольная сумма UDP сошлась,
// собеседник разобрал QUIC и ответил, ответ раскрылся нашими ключами.
func TestFragmentedProbeReachesServer(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	addr := mustResolve(t, box.addr())
	spec := buildInitial("example.org", V1, 1200, 0)
	if spec.pkts == nil {
		t.Fatal("зонд не собрался")
	}
	spec.frag = &fragPlan{pos1: 8}

	res := exchange(ctx, addr, spec, 3*time.Second)
	if res.err != nil {
		// Без CAP_NET_RAW сырой сокет не открыть — это не провал замера, а
		// отсутствие прав, и молчать об этом нельзя.
		t.Skipf("сырой сокет недоступен: %v", res.err)
	}
	if !res.ok {
		t.Fatal("фрагментированный Initial не дошёл до собеседника по петле — " +
			"значит сломана сборка заголовков, а не сеть")
	}
}

// ПЕРЕКРЫВАЮЩИЕСЯ ФРАГМЕНТЫ. Замер на живом Linux 6.8 (наш узел, 04.09):
// приёмник их НЕ собирает — ядро видит перекрытие и выбрасывает всю очередь
// сборки целиком (IpExtReasmOverlaps=1, IpReasmFails=4). Без перекрытия те же
// три фрагмента собираются штатно.
//
// Отсюда следствие для продукта, а не только для зонда: боевые плечи
// z2k_ipfrag3 и z2k_ipfrag3_tiny задают ipfrag_overlap12/overlap23, и на любом
// Linux-сервере такая датаграмма до приложения не доедет. Ротатор спишет это
// как неудачную стратегию, а выглядеть будет как блокировка.
//
// Тест не требует конкретного исхода: на другом ядре политика может быть иной.
// Он фиксирует наблюдение и проверяет, что зонд не делает из него выводов
// вслепую — за это отвечает TestFragArmNotRecommendedWhenSilent ниже.
func TestOverlappingFragmentsObservedBehaviour(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	addr := mustResolve(t, box.addr())
	spec := buildInitial("example.org", V1, 1200, 0)
	if spec.pkts == nil {
		t.Fatal("зонд не собрался")
	}
	spec.frag = &fragPlan{three: true, pos1: 8, pos2: 32, ov12: 8, ov23: 8, disorder: true}

	res := exchange(ctx, addr, spec, 3*time.Second)
	if res.err != nil {
		t.Skipf("сырой сокет недоступен: %v", res.err)
	}
	if res.ok {
		t.Log("это ядро перекрывающиеся фрагменты собирает")
	} else {
		t.Log("это ядро перекрывающиеся фрагменты отвергает — плечи с overlap " +
			"на таком приёмнике трафик не доставляют")
	}
}

// ГЛАВНЫЙ ИНВАРИАНТ БЕЗОПАСНОСТИ: плечо, которое не доставило ни одного
// ответа, не должно попадать ни в свойства, ни в строку.
//
// Цена ошибки несимметрична. Не предложить рабочее плечо — упущенная выгода.
// Предложить нерабочее — человек вставит строку, и его трафик тихо умрёт, а
// связать одно с другим он не сможет.
func TestFragArmNotRecommendedWhenSilent(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	res := Run(ctx, "rutracker.org", Options{
		Addr: box.addr(), Repeats: 2, Timeout: 300 * time.Millisecond,
		AllowLoopback: true, Parallel: 4,
	})
	if res.Verdict != VerdictContent {
		t.Fatalf("вердикт %q (%s)", res.Verdict, res.Reason)
	}
	// Стенд режет имя при любой упаковке, значит ни одно плечо фрагментации
	// пройти не могло.
	if res.Props.FragArm != "" {
		t.Errorf("плечо фрагментации %q засчитано, хотя ответа не было", res.Props.FragArm)
	}
	if strings.Contains(res.Strategy, "ipfrag") {
		t.Errorf("в строку попала фрагментация, хотя она не прошла: %s", res.Strategy)
	}
}

// Разделяем две причины: «три фрагмента» и «перекрытие». Если без перекрытия
// собирается, а с перекрытием нет — значит приёмник его отвергает, и боевые
// плечи z2k_ipfrag3 на таком приёмнике не обход, а обрыв.
func TestThreeFragmentsWithoutOverlap(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	addr := mustResolve(t, box.addr())
	spec := buildInitial("example.org", V1, 1200, 0)
	if spec.pkts == nil {
		t.Fatal("зонд не собрался")
	}
	spec.frag = &fragPlan{three: true, pos1: 8, pos2: 32}

	res := exchange(ctx, addr, spec, 3*time.Second)
	if res.err != nil {
		t.Skipf("сырой сокет недоступен: %v", res.err)
	}
	if !res.ok {
		t.Fatal("три фрагмента без перекрытия не собрались")
	}
}
