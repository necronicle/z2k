package decision

import (
	"testing"

	"github.com/necronicle/z2k/z2k-detect/internal/prober"
)

// Блок по адресу не должен превращаться в Hot.
//
// Полевой случай 19.08.2026, 4pda.to. Проба отработала правильно: постучалась
// к тому же адресу с нейтральным именем example.com, получила тот же таймаут и
// вынесла PathIP с пояснением «режут адрес, не имя». А вердикт всё равно вышел
// Hot, и отчёт сам себе противоречил — тремя строками ниже человек читал
// «ничего делать не надо, autocircular подберёт страту автоматически».
//
// Цена ошибки не косметическая. Hot означает публикацию домена в bypass, после
// чего ротатор впустую перебирает весь арсенал пула — а заодно двигает
// стратегию остальным доменам того же ключа. Пакетные техники блок по адресу
// не обходят в принципе (manual, «Блокировка по IP»).
func TestClassifyIPBlockIsWatchNotHot(t *testing.T) {
	r := prober.Result{
		DNSOK:       true,
		TCPOK:       true, // handshake проходит, режут уже после ClientHello
		TLSOK:       false,
		FailureCode: prober.CodeTLSHandshakeTimeout,
		PathVerdict: prober.PathIP,
		PathReason:  "с нейтральным именем example.com тот же адрес тоже молчит",
	}
	if got := Classify(r); got != Watch {
		t.Fatalf("блок по адресу: получили %q, ожидали %q", got, Watch)
	}
}

// Тот же отказ, но режут по ИМЕНИ — это наш случай, обход применим.
// Отличие от предыдущего теста ровно в одном поле, чтобы было видно, что
// решает именно PathVerdict, а не код ошибки.
func TestClassifySNIBlockStaysHot(t *testing.T) {
	r := prober.Result{
		DNSOK:       true,
		TCPOK:       true,
		TLSOK:       false,
		FailureCode: prober.CodeTLSHandshakeTimeout,
		PathVerdict: prober.PathSNI,
		PathReason:  "с нейтральным именем example.com тот же адрес отвечает",
	}
	if got := Classify(r); got != Hot {
		t.Fatalf("блок по имени: получили %q, ожидали %q", got, Hot)
	}
}

// Порт не отвечает вовсе — проба тоже ставит PathIP. Раньше это давало Hot.
func TestClassifyDeadPortIsWatch(t *testing.T) {
	r := prober.Result{
		DNSOK:       true,
		TCPOK:       false,
		FailureCode: prober.CodeTCPTimeout,
		PathVerdict: prober.PathIP,
		PathReason:  "порт 443 не отвечает — блок по адресу или порту",
	}
	if got := Classify(r); got != Watch {
		t.Fatalf("мёртвый порт: получили %q, ожидали %q", got, Watch)
	}
}

// Старые пробы и ручные вызовы PathVerdict не заполняют. Поведение для них
// обязано остаться прежним, иначе правка молча поломает всё, что зовёт
// Classify без пути.
func TestClassifyWithoutPathVerdictUnchanged(t *testing.T) {
	cases := []struct {
		name string
		in   prober.Result
		want Verdict
	}{
		{"dns упал", prober.Result{DNSOK: false}, Ignore},
		{"tcp упал", prober.Result{DNSOK: true, TCPOK: false}, Hot},
		{"tls упал", prober.Result{DNSOK: true, TCPOK: true, TLSOK: false}, Hot},
		{"всё живо", prober.Result{DNSOK: true, TCPOK: true, TLSOK: true}, Ignore},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Classify(c.in); got != c.want {
				t.Fatalf("получили %q, ожидали %q", got, c.want)
			}
		})
	}
}

// Успешная проба PathVerdict не заполняет вовсе (classifyPath выходит сразу),
// так что пустое значение не должно случайно попасть в ветку блока.
func TestClassifyEmptyPathVerdictIsNotWatch(t *testing.T) {
	r := prober.Result{DNSOK: true, TCPOK: true, TLSOK: true, PathVerdict: ""}
	if got := Classify(r); got == Watch {
		t.Fatalf("пустой PathVerdict не должен давать %q", Watch)
	}
}
