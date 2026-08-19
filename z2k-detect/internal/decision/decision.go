// Package decision classifies probe outcomes into engine states.
//
// Current policy:
//
//	DNS failed              → Ignore  (domain doesn't resolve — not ours)
//	Блок по адресу          → Watch   (пакетные техники бессильны — нужен туннель)
//	TCP:443 failed          → Hot     (reachable name, unreachable host → likely blocked)
//	TLS handshake failed    → Hot     (TLS interception / blackhole → likely blocked)
//	HTTP cutoff             → Hot     (TLS up but stream severed mid-response — L7 DPI signature)
//	Everything OK           → Ignore  (direct path works — no need to tunnel)
//
// HTTPOK is tri-state: nil means the probe didn't run the HTTP stage (older
// remote prober, manual call site that skipped) — fall back to TCP+TLS
// verdict only. ptr(false) means we tried and got severed; ptr(true) means
// we read a real response OR the server actively rejected with a typed
// TLS alert (mTLS challenge etc., handled inside prober — see
// prober.IsServerReachable). Either way the path is reachable, so Ignore.
package decision

import "github.com/necronicle/z2k/z2k-detect/internal/prober"

type Verdict string

const (
	Ignore Verdict = "ignore"
	Watch  Verdict = "watch"
	Hot    Verdict = "hot"
)

// Classify maps a probe result to a verdict.
func Classify(r prober.Result) Verdict {
	if !r.DNSOK {
		return Ignore
	}
	// Блок ПО АДРЕСУ пакетными техниками не обходится — manual, «Блокировка
	// по IP»: «zapret не может обойти блок по IP». Проба это уже установила,
	// постучавшись к тому же адресу с нейтральным именем example.com.
	//
	// Hot здесь был бы прямым вредом. Он означает «домен в bypass, autocircular
	// подберёт стратегию», а подбирать нечего: ротатор впустую переберёт весь
	// арсенал, каждый неудачный перебор — это ещё и смена стратегии для всех
	// остальных доменов того же пула. Плюс с -publish такой домен уезжает в
	// discovered-domains.txt и остаётся там навсегда.
	//
	// Watch: заблокировано, но не нашими средствами. Помогает другой адрес
	// (свежий резолв) или туннель.
	if r.PathVerdict == prober.PathIP {
		return Watch
	}
	if !r.TCPOK || !r.TLSOK {
		return Hot
	}
	if r.HTTPOK != nil && !*r.HTTPOK {
		return Hot
	}
	// 1.3 ClientHello-targeted block: TLSOK is true (the 1.2 fallback
	// succeeded), HTTPOK is true (server responded over 1.2), but the
	// browser the user actually drives speaks 1.3 by default. Treating
	// this as Ignore would silently leave the user breaking; treating
	// it as Hot adds the domain to bypass list and keeps Chrome/Firefox 1.3 working.
	if r.FailureCode == prober.CodeTLS13Block {
		return Hot
	}
	return Ignore
}
