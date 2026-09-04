package classify

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"net"
	"sync"
	"time"
)

// ОТВЕТНОЕ НАПРАВЛЕНИЕ.
//
// Всё остальное в этом пакете меряет направление клиент → сервер: проходит ли
// НАШ ClientHello. Но у TLS 1.2 есть класс блокировки, которого при таком
// замере не видно вовсе.
//
// В TLS 1.2 сертификат сервера едет ОТКРЫТЫМ ТЕКСТОМ и содержит имя домена.
// Коробка может пропустить запрос и убить ОТВЕТ — на сертификате. Тогда наш
// ClientHello доходит, ServerHello возвращается, инструмент честно объявляет
// «проходит как есть», а сайт у человека не открывается. Вердикт получается
// не просто неточным, а противоположным правде.
//
// В TLS 1.3 такого класса не существует: там всё после ServerHello уже
// зашифровано, и резать по имени в сертификате нечего. Поэтому зонд насильно
// договаривается на 1.2 — именно так коробка увидела бы сертификат в открытую.
//
// Оракул тот же, что и везде: сравнение с контролем. Рукопожатие с нейтральным
// именем на ТОТ ЖЕ адрес обязано завершаться. Не завершается — значит сервер
// не умеет 1.2 или мешает что-то ещё, и вывода мы не делаем.

// ResponseVerdict — что показал зонд ответного направления.
type ResponseVerdict string

const (
	// RespNotApplicable — проверить не удалось: сервер не говорит по TLS 1.2,
	// либо контроль не завершается. Это НЕ «всё хорошо», это «не измерено».
	RespNotApplicable ResponseVerdict = "not_applicable"
	// RespClear — рукопожатие 1.2 доходит до конца, сертификат не режут.
	RespClear ResponseVerdict = "clear"
	// RespBlocked — запрос проходит, а ответ убивают: с нашим именем
	// рукопожатие не завершается ни разу, с нейтральным на тот же адрес —
	// каждый раз.
	RespBlocked ResponseVerdict = "blocked"
	// RespFlaky — не воспроизводится.
	RespFlaky ResponseVerdict = "flaky"
)

// ResponseResult — итог зонда ответного направления.
type ResponseResult struct {
	Verdict ResponseVerdict `json:"verdict"`
	Reason  string          `json:"reason"`
	// Target и Control — сколько рукопожатий из Repeats дошли до конца.
	Target  int `json:"target"`
	Control int `json:"control"`
}

// ProbeResponse проверяет, не режут ли ОТВЕТ сервера.
//
// Зовётся только там, где запрос уже признан проходящим: если режут запрос,
// про ответ говорить рано.
func ProbeResponse(ctx context.Context, addr, sni string, opt Options) ResponseResult {
	opt.withDefaults()

	target := countHandshakes(ctx, addr, sni, opt)
	// Контроль ОБЯЗАН быть другим именем на том же адресе. Если бы мы взяли
	// то же самое, молчали бы оба, и «режут ответ» получилось бы из
	// собственной ошибки ввода.
	control := countHandshakes(ctx, addr, neutralSNI(), opt)

	res := ResponseResult{Target: target, Control: control}
	switch {
	case control == 0:
		res.Verdict = RespNotApplicable
		res.Reason = "контрольное рукопожатие по TLS 1.2 не завершается — сервер его не поддерживает " +
			"или мешает что-то ещё; про ответное направление вывода нет"
	case target == opt.Repeats:
		res.Verdict = RespClear
		res.Reason = "рукопожатие TLS 1.2 доходит до конца — сертификат не режут"
	case target == 0:
		res.Verdict = RespBlocked
		res.Reason = "запрос проходит, а рукопожатие не завершается: с нейтральным именем на тот же адрес " +
			"оно завершается каждый раз. Значит режут ОТВЕТ — сертификат в TLS 1.2 идёт открытым текстом"
	default:
		res.Verdict = RespFlaky
		res.Reason = fmt.Sprintf("рукопожатий дошло %d из %d — не воспроизводится", target, opt.Repeats)
	}
	return res
}

// countHandshakes считает, сколько рукопожатий TLS 1.2 дошли до конца.
//
// ПОВТОРЫ ИДУТ ВЕЕРОМ, а не по очереди. Рукопожатие к цели, которую режут,
// стоит полного таймаута, и шесть таких подряд (три на имя, три на контроль)
// добавляли к замеру полминуты: на rutracker.org прогон вырос с 4 до 39 секунд.
// Соединения независимы, общего состояния у них нет — очередь тут ничего не
// давала, кроме ожидания.
func countHandshakes(ctx context.Context, addr, sni string, opt Options) int {
	var (
		mu   sync.Mutex
		done int
		wg   sync.WaitGroup
	)
	for i := 0; i < opt.Repeats; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if handshake12(ctx, addr, sni, opt) {
				mu.Lock()
				done++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return done
}

// respTimeout — потолок на одно рукопожатие проверки.
//
// Он НИЖЕ общего: сюда мы попадаем только тогда, когда сервер уже ответил на
// наш ClientHello, то есть он рядом и жив. Ждать его шесть секунд незачем, а
// цена ожидания — прямое время в глазах человека.
func respTimeout(opt Options) time.Duration {
	if opt.Timeout > 0 && opt.Timeout < 3*time.Second {
		return opt.Timeout
	}
	return 3 * time.Second
}

func handshake12(ctx context.Context, addr, sni string, opt Options) bool {
	to := respTimeout(opt)
	d := net.Dialer{Control: markControl, Timeout: to}
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return false
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(to))

	c := tls.Client(raw, &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS12,
	})
	return c.HandshakeContext(ctx) == nil
}

// neutralSNI — имя для контроля. Домен example.com зарезервирован IANA
// (RFC 2606) и в списках не встречается; случайная метка спереди убирает
// попадание в кэши и в состояние коробки.
func neutralSNI() string {
	var b [5]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("z%x.example.com", b)
}

// triggerSNI достаёт имя из названия триггера: TLSTrigger кладёт туда "tls:<имя>".
// Для сырого триггера имени нет, и зонд ответного направления смысла не имеет.
func triggerSNI(t Trigger) string {
	const p = "tls:"
	if len(t.Name) > len(p) && t.Name[:len(p)] == p {
		return t.Name[len(p):]
	}
	return ""
}
