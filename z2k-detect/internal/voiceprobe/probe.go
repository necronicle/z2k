package voiceprobe

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Verdict — что происходит с голосовым потоком.
type Verdict string

const (
	// VerdictClear — голосовой сервер отвечает, резать нечего.
	VerdictClear Verdict = "clear"
	// VerdictBlocked — сервер молчит, а публичный STUN на том же канале
	// отвечает. Значит UDP ходит, а этот поток режут.
	VerdictBlocked Verdict = "blocked"
	// VerdictNoUDP — молчит и публичный STUN: на канале не ходит UDP вообще
	// или режут целиком. Обходить голос отдельно бессмысленно.
	VerdictNoUDP Verdict = "no_udp"
	// VerdictNoCall — живого разговора не нашлось, мерить нечего.
	VerdictNoCall Verdict = "no_call"
	// VerdictFlaky — не воспроизводится.
	VerdictFlaky Verdict = "flaky"
)

// Step — строка трассы.
type Step struct {
	Name     string `json:"name"`
	Sent     int    `json:"sent"`
	Answered int    `json:"answered"`
	MS       int64  `json:"ms,omitempty"`
	Note     string `json:"note,omitempty"`
}

// Result — что показал прогон.
type Result struct {
	Target   string  `json:"target"`
	Verdict  Verdict `json:"verdict"`
	Reason   string  `json:"reason"`
	Repeats  int     `json:"repeats"`
	Probes   int     `json:"probes"`
	Duration string  `json:"duration"`
	// Marked — удалось ли пометить сокет. Без метки зонд идёт через наш же
	// обход и меряет его, а не коробку провайдера: на голосовых портах наш
	// профиль стоит ровно там же.
	Marked   bool     `json:"marked"`
	FakeArm  string   `json:"fake_arm,omitempty"`
	Strategy string   `json:"strategy,omitempty"`
	Notes    []string `json:"notes,omitempty"`
	Trace    []Step   `json:"trace,omitempty"`
}

// Options — настройки прогона.
type Options struct {
	Repeats int
	Timeout time.Duration
	// Target — мерить именно этот адрес вместо поиска живого разговора.
	Target string
	// ControlServer — публичный STUN для проверки, что UDP на канале ходит.
	ControlServer string
	BlobDir       string
}

func (o *Options) withDefaults() {
	if o.Repeats <= 0 {
		o.Repeats = 3
	}
	if o.Timeout <= 0 {
		o.Timeout = 3 * time.Second
	}
	if o.ControlServer == "" {
		// Замер 04.09 с роутера: Cloudflare на 3478 отвечает за 30 мс,
		// Google на 19302 молчит целиком. Берём тот, что отвечает.
		o.ControlServer = "stun.cloudflare.com:3478"
	}
	if o.BlobDir == "" {
		o.BlobDir = "/opt/zapret2/files/fake"
	}
}

// voiceBlobs — фальшивки боевого профиля discord_udp, в порядке проверки.
var voiceBlobs = []struct{ name, file string }{
	{"active_discord_udp", "active_discord_udp.bin"},
	{"stun", "stun.bin"},
	{"quic_dbankcloud", "quic_initial_dbankcloud_ru.bin"},
}

// Run меряет голосовой поток.
func Run(ctx context.Context, opt Options) Result {
	opt.withDefaults()
	started := time.Now()
	res := Result{Repeats: opt.Repeats, Marked: markSupported()}
	finish := func(v Verdict, reason string) Result {
		res.Verdict, res.Reason = v, reason
		res.Duration = time.Since(started).Round(time.Millisecond).String()
		return res
	}
	if !res.Marked {
		res.Notes = append(res.Notes,
			"сокет не пометить: зонд пойдёт через наш же обход, и замер будет не про коробку провайдера")
	}

	addr, err := resolveTarget(opt)
	if err != nil {
		return finish(VerdictNoCall, err.Error())
	}
	res.Target = addr.String()

	ask := func(name string, mk func() ([][]byte, [12]byte)) Step {
		st := measure(ctx, addr, opt, mk)
		st.Name = name
		res.Probes += st.Sent
		res.Trace = append(res.Trace, st)
		return st
	}

	// ШАГ 1. Достижим ли голосовой сервер. Оракул настоящий: сервер возвращает
	// наш же адрес, а совпадение идентификатора транзакции доказывает, что
	// ответил именно он.
	direct := ask("голосовой сервер: STUN как есть", plainStun)
	if direct.Answered == opt.Repeats {
		return finish(VerdictClear, "голосовой сервер отвечает — резать нечего")
	}
	if direct.Answered > 0 {
		return finish(VerdictFlaky, fmt.Sprintf(
			"ответов %d из %d — не воспроизводится, вердикт выносить нельзя", direct.Answered, opt.Repeats))
	}

	// ШАГ 2. КОНТРОЛЬ. Публичный STUN на том же канале. Отвечает — UDP ходит,
	// и молчание голосового сервера про него самого. Молчит — режут UDP
	// вообще, и голос тут ни при чём.
	ctlAddr, cerr := net.ResolveUDPAddr("udp4", opt.ControlServer)
	if cerr == nil {
		ctl := measure(ctx, ctlAddr, opt, plainStun)
		ctl.Name = "контроль: публичный STUN"
		res.Probes += ctl.Sent
		res.Trace = append(res.Trace, ctl)
		if ctl.Answered == 0 {
			return finish(VerdictNoUDP,
				"молчит и голосовой сервер, и публичный STUN: на этом канале не ходит UDP "+
					"или его режут целиком — обходить голос отдельно бессмысленно")
		}
	}

	res.Verdict = VerdictBlocked
	res.Reason = "голосовой сервер молчит, а публичный STUN на том же канале отвечает: " +
		"UDP ходит, режут именно этот поток"
	askVoiceArms(ctx, addr, opt, ask, &res)
	res.Duration = time.Since(started).Round(time.Millisecond).String()
	return res
}

// askVoiceArms перебирает приёмы боевого профиля: фальшивка перед настоящим
// пакетом, число копий, укороченный TTL. Ровно то, чем discord_udp и работает.
func askVoiceArms(ctx context.Context, addr *net.UDPAddr, opt Options,
	ask func(string, func() ([][]byte, [12]byte)) Step, res *Result) {

	try := func(name string, body []byte, copies, ttl int) bool {
		st := ask(name, func() ([][]byte, [12]byte) {
			req, tx := BindingRequest()
			pre := make([][]byte, 0, copies+1)
			for i := 0; i < copies; i++ {
				pre = append(pre, body)
			}
			return append(pre, req), tx
		})
		return st.Answered == opt.Repeats
	}

	for _, b := range voiceBlobs {
		body := loadBlob(opt.BlobDir, b.file)
		if body == nil {
			res.Trace = append(res.Trace, Step{Name: "фальшивка " + b.name,
				Note: "не измерено: нет файла блоба (запуск не на роутере)"})
			continue
		}
		for _, n := range []int{1, 6} {
			if try(fmt.Sprintf("фальшивка %s ×%d", b.name, n), body, n, 0) {
				res.FakeArm = fmt.Sprintf("%s:repeats=%d", b.name, max(n, 2))
				res.Strategy = "--lua-desync=fake:payload=all:blob=" + b.name +
					fmt.Sprintf(":repeats=%d", max(n, 2))
				return
			}
		}
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func plainStun() ([][]byte, [12]byte) {
	req, tx := BindingRequest()
	return [][]byte{req}, tx
}

func loadBlob(dir, name string) []byte {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil || len(b) < 16 {
		return nil
	}
	return b
}

func resolveTarget(opt Options) (*net.UDPAddr, error) {
	if opt.Target != "" {
		return net.ResolveUDPAddr("udp4", opt.Target)
	}
	targets, err := FindVoiceTargets()
	if err != nil {
		return nil, err
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("живого разговора не видно. Начните звонок в Дискорде и " +
			"повторите замер: у голоса нет имени, которое можно вписать, и адрес берётся " +
			"из идущего разговора")
	}
	return &net.UDPAddr{IP: targets[0].IP, Port: targets[0].Port}, nil
}

// measure гоняет зонд Repeats раз. Каждый повтор — свой сокет и свой
// идентификатор транзакции: чужой ответ не должен сойти за наш.
func measure(ctx context.Context, addr *net.UDPAddr, opt Options,
	mk func() ([][]byte, [12]byte)) Step {

	var (
		mu       sync.Mutex
		answered int
		best     int64
		note     string
		wg       sync.WaitGroup
	)
	for i := 0; i < opt.Repeats; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pkts, tx := mk()
			ms, ok, err := exchange(ctx, addr, pkts, tx, opt.Timeout)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case ok:
				answered++
				if best == 0 || ms < best {
					best = ms
				}
			case err != nil && note == "":
				note = err.Error()
			}
		}()
	}
	wg.Wait()
	return Step{Sent: opt.Repeats, Answered: answered, MS: best, Note: note}
}

func exchange(ctx context.Context, addr *net.UDPAddr, pkts [][]byte, tx [12]byte,
	timeout time.Duration) (int64, bool, error) {

	d := net.Dialer{Control: markControl, Timeout: timeout}
	c, err := d.DialContext(ctx, "udp4", addr.String())
	if err != nil {
		return 0, false, err
	}
	defer c.Close()

	start := time.Now()
	for _, p := range pkts {
		if _, err := c.Write(p); err != nil {
			return 0, false, err
		}
	}
	_ = c.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 1500)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return 0, false, nil // тишина — исход измерения, а не ошибка
		}
		if _, _, perr := ParseBindingResponse(buf[:n], tx); perr == nil {
			return time.Since(start).Milliseconds(), true, nil
		}
		if time.Since(start) > timeout {
			return 0, false, nil
		}
	}
}
