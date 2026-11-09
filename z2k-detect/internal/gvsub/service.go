package gvsub

// Служба подмены плохих адресов googlevideo.
//
// Три источника, один механизм проверки:
//   - ответ DNS устройству (придерживается, пока адрес не проверен) — чтобы
//     даже первое соединение шло уже на рабочий адрес;
//   - conntrack (соединение без ответа сервера) — смена состояния между
//     ответами DNS;
//   - таймер — перепроверка уже стоящих подмен в обе стороны.
//
// Состояние адресов меняется (замер 06.11 → 09.11: плохие стали хорошими и
// наоборот), поэтому вердикт живёт недолго и перепроверяется.

import (
	"context"
	"encoding/json"
	"log"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// Вердикт без перепроверки при новом ответе DNS. Не дольше: состояние
	// адресов меняется, а пачка запросов одного устройства укладывается в
	// секунды и не должна платить задержкой каждый раз.
	CacheTTL = 60 * time.Second
	// Потолок придержки ответа DNS. Плохой адрес с найденным соседом на
	// роутере Марка обходился в 1,4–1,5 с (проверка ~1,1 с + первый ответивший
	// сосед ~0,3 с); дольше ждут только адреса, у которых соседа нет вовсе, и
	// держать ради них DNS устройства нечего: поиск продолжается в фоне.
	HoldMax = 2 * time.Second
	// Поиск соседа для одного адреса, если в прошлый раз рабочих машин в
	// кластере не нашлось, — не чаще. Повторный поиск каждую минуту для
	// каждого такого адреса держал в conntrack ~1000 соединений роутера к
	// Google (10.11.2026), а состояние машин так быстро не меняется.
	SearchPause = 10 * time.Minute
	// Шаг таймера: перепроверка подмен и фоновая перепроверка адресов, которые
	// сейчас в ходу. Вдвое чаще срока вердикта — чтобы к следующему ответу DNS
	// вердикт по такому адресу всегда был свежим и ответ ничего не ждал.
	RecheckEvery = CacheTTL / 2
	// «В ходу» — адрес приходил в ответе DNS не раньше срока жизни записи
	// googlevideo (1800 с): пока запись живёт у устройств, они ходят на этот
	// адрес, и состояние его надо знать заранее.
	ActiveFor = 30 * time.Minute
	// Подмена, адрес которой давно не приходил в ответах DNS, снимается:
	// устройства его уже не используют.
	IdleDrop = time.Hour
	// Опрос conntrack и повторная проверка по сигналу детектора не чаще.
	PollEvery     = 2 * time.Second
	DetectorPause = 10 * time.Second
)

type entry struct {
	verdict  Verdict
	checked  time.Time
	seen     time.Time // последний ответ DNS с адресом или соединение к нему
	name     string    // имя из ответа DNS: по нему ищутся машины того же кластера
	searched time.Time // последний поиск соседа без результата
}

// stallMark — счётчики соединения на прошлом опросе: сбрасывается только то,
// что за опрос не сдвинулось. Проба z2k с окном 1 сама выглядит «зависшей»
// (мелкие куски ответа), и сброс на первом же снимке убивал её посреди
// обмена (ревью 10.11.2026).
type stallMark struct {
	bytes, pkts int
}

// KillForget — сколько помнить сброшенное соединение. Дольше, чем оно живёт
// после сброса: иначе пересозданная запись того же соединения сбрасывалась
// бы снова и снова.
const KillForget = time.Minute

type mapping struct {
	Good  netip.Addr   `json:"good"`
	Since time.Time    `json:"since"`
	Spare []netip.Addr `json:"spare,omitempty"`
}

// Service — состояние службы. Безопасна для вызова из разных горутин.
type Service struct {
	Checker    Checker
	Rules      Rules
	Resolver   Resolver
	Now        func() time.Time
	StatusPath string
	// IPFile — список адресов из ответов DNS для профиля движка (--ipset).
	// Движок узнаёт имя хоста только из самого соединения, и первое соединение
	// к новому адресу шло мимо профиля googlevideo, без пробы: плохой сервер
	// молчал, Safari ждал ~2,5 с и уходил на другой (замер 10.11.2026, шортс
	// 11,8 с). Файл пишется ДО того, как отпустить ответ DNS, а движок
	// перечитывает его при изменении сам.
	IPFile string
	// Local — адрес самого роутера. Его соединения детектор не считает: это
	// проверки самой службы, и без фильтра каждая проверка плохого адреса
	// оставляла в conntrack «зависшее соединение», детектор запускал проверку
	// снова — цикл каждые 12 с (ночь на 10.11.2026).
	Local func(netip.Addr) bool
	// Kill удаляет запись conntrack: соединение к плохому адресу, открытое до
	// подмены, браузер держит минутами и ждёт ответа на нём (10.11.2026).
	Kill func(Flow) error

	mu       sync.Mutex
	known    map[netip.Addr]*entry
	maps     map[netip.Addr]*mapping
	inflight map[netip.Addr]chan struct{}
	pending  map[string]time.Time // детектор: соединение без ответа с первого опроса
	killed   map[string]time.Time // сброшенные соединения: второй раз не трогаем
	stall    map[string]stallMark // зависшие до подмены: счётчики прошлого опроса
	closed   bool                 // Shutdown: фоновые проверки подмен не ставят

	ipmu    sync.Mutex          // запись IPFile
	ipLast  string              // что записано в IPFile
	qmu     sync.Mutex          // строки отказа QUIC: применяются вне mu
	quicSet map[netip.Addr]bool // где отказ QUIC стоит (под qmu)
	// Кластер, где в прошлый поиск рабочих машин не нашлось: второй плохой
	// адрес того же кластера не ищет заново (иначе ответ DNS по нему ждал
	// весь поиск — 2,1 с на роутере Марка).
	deadCluster map[string]time.Time
}

func (s *Service) init() {
	if s.known == nil {
		s.known = map[netip.Addr]*entry{}
		s.maps = map[netip.Addr]*mapping{}
		s.inflight = map[netip.Addr]chan struct{}{}
		s.pending = map[string]time.Time{}
		s.killed = map[string]time.Time{}
		s.stall = map[string]stallMark{}
		s.deadCluster = map[string]time.Time{}
	}
	if s.Now == nil {
		s.Now = time.Now
	}
}

// OnDNS отмечает адреса из ответа DNS и возвращает канал, который закроется,
// когда все непроверенные адреса проверены и подмены поставлены. Свежие
// вердикты не придерживают ответ.
func (s *Service) OnDNS(name string, addrs []netip.Addr) <-chan struct{} {
	s.mu.Lock()
	s.init()
	now := s.Now()
	var waits []chan struct{}
	for _, a := range addrs {
		e := s.known[a]
		if e == nil {
			e = &entry{}
			s.known[a] = e
		}
		e.seen = now
		if name != "" {
			e.name = name
		}
		if e.verdict != Unknown && now.Sub(e.checked) < CacheTTL || s.pausedLocked(a, e) {
			continue
		}
		waits = append(waits, s.startLocked(a))
	}
	s.mu.Unlock()
	s.writeIPs()
	done := make(chan struct{})
	go func() {
		for _, w := range waits {
			<-w
		}
		close(done)
	}()
	return done
}

// clusterKey — кластер отдельно для IPv4 и IPv6: машины кластера в двух
// семействах разные, и «на IPv4 рабочих нет» ничего не говорит об IPv6.
// Общий ключ 10.11.2026 не дал искать замену на IPv6 для rr4.sn-aj5go5-53,
// когда у неё отказал сосед (на IPv4 в кластере рабочих не было), — подмена
// снялась, новая не встала, у Марка встал ролик.
func clusterKey(cluster string, a netip.Addr) string {
	if a.Is6() {
		return cluster + "/6"
	}
	return cluster
}

// pausedLocked — плохой адрес без подмены, поиск соседа для которого на
// паузе (SearchPause). Проверять его до конца паузы незачем: «плохой» ничего
// не меняет (mapTo вернётся сразу), «рабочий» тоже — подмены нет. Без этого
// каждый такой адрес перепроверялся раз в 30 с, а ответ DNS по нему
// придерживался на всю проверку (~1 с).
func (s *Service) pausedLocked(a netip.Addr, e *entry) bool {
	if e.verdict != Bad || s.maps[a] != nil {
		return false
	}
	now := s.Now()
	if !e.searched.IsZero() && now.Sub(e.searched) < SearchPause {
		return true
	}
	if c, _, ok := ParseCluster(e.name); ok {
		if t, ok := s.deadCluster[clusterKey(c, a)]; ok && now.Sub(t) < SearchPause {
			return true
		}
	}
	return false
}

// startLocked запускает проверку адреса или присоединяется к идущей.
func (s *Service) startLocked(a netip.Addr) chan struct{} {
	if ch, ok := s.inflight[a]; ok {
		return ch
	}
	ch := make(chan struct{})
	s.inflight[a] = ch
	go func() {
		s.resolve(a)
		s.mu.Lock()
		delete(s.inflight, a)
		s.mu.Unlock()
		close(ch)
		s.writeStatus()
	}()
	return ch
}

// resolve проверяет адрес и приводит подмену в соответствие.
func (s *Service) resolve(a netip.Addr) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*HoldMax)
	defer cancel()
	v := s.Checker.Check(ctx, a)

	s.mu.Lock()
	if s.closed || s.known[a] == nil {
		s.mu.Unlock()
		return
	}
	e := s.known[a]
	e.verdict, e.checked = v, s.Now()
	m := s.maps[a]
	s.mu.Unlock()
	// Отказ QUIC нужен и без соседа: Bad — отказ, иначе снять.
	s.syncQUIC(false)

	switch {
	case m != nil && v == Good:
		s.unmap(a, m, "адрес снова отвечает")
	case m != nil:
		// Плохой по-прежнему плохой — жив ли сосед? Одиночный отказ проверки
		// случается и у рабочего соседа (10.11.2026: пять раз за день подмена
		// снималась и тут же ставилась на ТОГО ЖЕ соседа), поэтому снимаем
		// только после второго отказа подряд.
		if s.Checker.Check(ctx, m.Good) == Good || s.Checker.Check(ctx, m.Good) == Good {
			return
		}
		s.mu.Lock()
		spare := m.Spare
		s.mu.Unlock()
		s.unmap(a, m, "сосед перестал отвечать")
		if !s.mapTo(ctx, a, spare) {
			log.Printf("gvsub: %s — замена не найдена, идёт без подмены", a)
		}
	case v == Bad:
		_ = s.mapTo(ctx, a, nil)
	}
}

// syncQUIC приводит строки отказа QUIC к вердиктам: Bad — отказ, остальное
// и убранные адреса — без отказа. iptables — вне s.mu: под ней служба
// принимает ответы DNS и опрашивает conntrack, а одна команда на роутере идёт
// 50–100 мс. Желаемое берётся под s.mu, применяется под своей блокировкой;
// запоздалый вызов просто приводит к тому же состоянию (10.11.2026).
// reset — цепочку пересоздали пустой: забыть, что стояло.
func (s *Service) syncQUIC(reset bool) {
	s.qmu.Lock()
	defer s.qmu.Unlock()
	if reset || s.quicSet == nil {
		s.quicSet = map[netip.Addr]bool{}
	}
	s.mu.Lock()
	want := map[netip.Addr]bool{}
	if !s.closed {
		for a, e := range s.known {
			if e.verdict == Bad {
				want[a] = true
			}
		}
	}
	s.mu.Unlock()
	for a := range want {
		if !s.quicSet[a] || reset {
			if err := s.Rules.RejectQUIC(a); err != nil {
				log.Printf("gvsub: отказ QUIC %s: %v", a, err)
				continue
			}
			s.quicSet[a] = true
		}
	}
	for a := range s.quicSet {
		if !want[a] {
			if err := s.Rules.AllowQUIC(a); err != nil {
				log.Printf("gvsub: снять отказ QUIC %s: %v", a, err)
				continue
			}
			delete(s.quicSet, a)
		}
	}
}

// mapTo ищет рабочего соседа (сначала среди запасных) и ставит подмену.
func (s *Service) mapTo(ctx context.Context, bad netip.Addr, spare []netip.Addr) bool {
	var good netip.Addr
	var rest <-chan []netip.Addr
	for i, c := range spare {
		if s.Checker.Check(ctx, c) == Good {
			good = c
			ch := make(chan []netip.Addr, 1)
			ch <- spare[i+1:]
			rest = ch
			break
		}
	}
	if !good.IsValid() {
		s.mu.Lock()
		e := s.known[bad]
		var name string
		var last time.Time
		if e != nil {
			name, last = e.name, e.searched
		}
		s.mu.Unlock()
		if !last.IsZero() && s.Now().Sub(last) < SearchPause {
			return false // в прошлый раз в кластере рабочих не было — ждём
		}
		cluster, _, _ := ParseCluster(name)
		s.mu.Lock()
		dead, ok := s.deadCluster[clusterKey(cluster, bad)]
		s.mu.Unlock()
		if ok && cluster != "" && s.Now().Sub(dead) < SearchPause {
			return false
		}
		good, rest = s.search(bad, name)
		if !good.IsValid() {
			s.mu.Lock()
			if e != nil {
				e.searched = s.Now()
			}
			if c, _, ok := ParseCluster(name); ok {
				s.deadCluster[clusterKey(c, bad)] = s.Now()
			}
			s.mu.Unlock()
			log.Printf("gvsub: %s (%s) плохой, рабочей машины в кластере нет", bad, name)
			return false
		}
	}
	// Пока шла проверка, адрес могли убрать как брошенный — не возвращаем.
	s.mu.Lock()
	gone := s.known[bad] == nil || s.closed
	s.mu.Unlock()
	if gone {
		return false
	}
	if recreated, err := s.Rules.Ensure(); err != nil {
		log.Printf("gvsub: каркас правил: %v", err)
	} else if recreated {
		s.Reapply()
	}
	if err := s.Rules.Add(bad, good); err != nil {
		log.Printf("gvsub: %s → %s не поставлено: %v", bad, good, err)
		return false
	}
	m := &mapping{Good: good, Since: s.Now()}
	s.mu.Lock()
	if s.closed {
		// Shutdown прошёл, пока ставились правила: снимаем за собой.
		s.mu.Unlock()
		_ = s.Rules.Del(bad, good)
		return false
	}
	s.maps[bad] = m
	s.mu.Unlock()
	log.Printf("gvsub: %s → %s", bad, good)
	go func() {
		sp := <-rest
		s.mu.Lock()
		m.Spare = sp
		s.mu.Unlock()
	}()
	return true
}

// search проверяет остальные машины того же кластера разом и возвращает
// ПЕРВУЮ ответившую, не дожидаясь остальных: чем раньше встанет подмена, тем
// меньше соединений успеет уйти на плохой адрес. Остальные рабочие досчитываются в фоне и приходят в spares —
// запас на случай, если выбранная машина испортится. Без имени кластера
// соседа нет: адрес из чужого кластера видео этого кэша не отдаёт.
func (s *Service) search(bad netip.Addr, name string) (netip.Addr, <-chan []netip.Addr) {
	spares := make(chan []netip.Addr, 1)
	cluster, _, ok := ParseCluster(name)
	if !ok || s.Resolver == nil {
		spares <- nil
		return netip.Addr{}, spares
	}
	// Свой срок, а не срок вызывающего: досчёт запасных идёт после того, как
	// подмена уже поставлена и resolve вернулся.
	ctx, cancel := context.WithTimeout(context.Background(), 2*HoldMax)
	var cands []netip.Addr
	for _, a := range s.Resolver.Siblings(ctx, cluster, bad.Is6()) {
		if a != bad && a.Is6() == bad.Is6() {
			cands = append(cands, a)
		}
	}
	res := make(chan netip.Addr, len(cands))
	var wg sync.WaitGroup
	for _, c := range cands {
		wg.Add(1)
		go func(c netip.Addr) {
			defer wg.Done()
			if s.Checker.Check(ctx, c) == Good {
				res <- c
			}
		}(c)
	}
	go func() { wg.Wait(); close(res) }()
	if first, ok := <-res; ok {
		go func() {
			defer cancel()
			var rest []netip.Addr
			for c := range res {
				if len(rest) < 3 {
					rest = append(rest, c)
				}
			}
			spares <- rest
		}()
		return first, spares
	}
	cancel()
	spares <- nil
	return netip.Addr{}, spares
}

func (s *Service) unmap(bad netip.Addr, m *mapping, why string) {
	if err := s.Rules.Del(bad, m.Good); err != nil {
		log.Printf("gvsub: снять %s → %s: %v", bad, m.Good, err)
	}
	s.mu.Lock()
	if s.maps[bad] == m {
		delete(s.maps, bad)
	}
	s.mu.Unlock()
	log.Printf("gvsub: %s → %s снято: %s", bad, m.Good, why)
}

// OnConntrack — сигнал детектора. Любое соединение устройства к адресу из
// ответов DNS продлевает адрес (и его подмену). Соединение без данных от
// сервера, замеченное в двух опросах подряд, запускает проверку адреса, если
// он проверялся не только что.
func (s *Service) OnConntrack(flows []Flow) {
	s.mu.Lock()
	s.init()
	now := s.Now()
	live := map[string]bool{}
	var kill []Flow
	for _, f := range flows {
		if s.Local != nil && s.Local(f.Src) {
			continue
		}
		e := s.known[f.Dst]
		if e == nil {
			continue
		}
		e.seen = now
		if !f.Stuck {
			continue
		}
		if s.maps[f.Dst] != nil {
			// Подмена стоит, а соединение идёт на сам плохой адрес — открыто
			// до подмены. Если за опрос оно не сдвинулось, сбрасываем, чтобы
			// браузер переподключился уже на соседа.
			if f.ReplySrc != f.Dst {
				continue
			}
			live[f.Key] = true
			cur := stallMark{f.OrigBytes, f.ReplyPkts}
			prev, seen := s.stall[f.Key]
			s.stall[f.Key] = cur
			if _, done := s.killed[f.Key]; seen && prev == cur && !done {
				s.killed[f.Key] = now
				kill = append(kill, f)
			}
			continue
		}
		// Уже знаем, что плохой (соседа нет или подмена не встала), — ждём
		// срока вердикта, а не дёргаем проверку на каждом опросе.
		if e.verdict == Bad && now.Sub(e.checked) < CacheTTL || s.pausedLocked(f.Dst, e) {
			continue
		}
		live[f.Key] = true
		first, ok := s.pending[f.Key]
		if !ok {
			s.pending[f.Key] = now
			continue
		}
		if now.Sub(first) < PollEvery || now.Sub(e.checked) < DetectorPause {
			continue
		}
		s.startLocked(f.Dst)
	}
	for k := range s.pending {
		if !live[k] {
			delete(s.pending, k)
		}
	}
	for k := range s.stall {
		if !live[k] {
			delete(s.stall, k)
		}
	}
	for k, t := range s.killed {
		if now.Sub(t) > KillForget {
			delete(s.killed, k)
		}
	}
	killFn := s.Kill
	s.mu.Unlock()
	if killFn == nil {
		return
	}
	for _, f := range kill {
		if err := killFn(f); err != nil {
			log.Printf("gvsub: сбросить %s: %v", f.Key, err)
		} else {
			log.Printf("gvsub: сброшено зависшее соединение %s, открытое до подмены", f.Key)
		}
	}
}

// Tick — перепроверка каркаса и подмен, уборка давно не встречавшихся адресов.
func (s *Service) Tick() {
	if recreated, err := s.Rules.Ensure(); err != nil {
		log.Printf("gvsub: каркас правил: %v", err)
	} else if recreated {
		s.Reapply()
	}
	s.mu.Lock()
	s.init()
	now := s.Now()
	type drop struct {
		a netip.Addr
		m *mapping
	}
	var drops []drop
	for a, m := range s.maps {
		if e := s.known[a]; e == nil || now.Sub(e.seen) > IdleDrop {
			drops = append(drops, drop{a, m})
			delete(s.known, a) // до снятия: идущая проверка не вернёт подмену
			continue
		}
		s.startLocked(a)
	}
	for a, e := range s.known {
		if now.Sub(e.seen) > IdleDrop && s.maps[a] == nil {
			delete(s.known, a)
			continue
		}
		// Фоновая перепроверка адресов в ходу: ответ DNS по ним не ждёт
		// проверки, а смена состояния замечается за полминуты.
		// Непроверенные (подняты из файла состояния) — в пределах IdleDrop:
		// подмена живёт столько же, и перезапуск службы не должен снимать
		// подмены адресов, которые видели 30–60 мин назад (10.11.2026).
		active := now.Sub(e.seen) < ActiveFor || e.verdict == Unknown
		if s.maps[a] == nil && active && now.Sub(e.checked) >= RecheckEvery && !s.pausedLocked(a, e) {
			s.startLocked(a)
		}
	}
	s.mu.Unlock()
	for _, d := range drops {
		s.unmap(d.a, d.m, "адрес давно не встречался")
	}
	s.syncQUIC(false)
	s.writeIPs()
	s.writeStatus()
}

// Mappings — снимок подмен (для статуса и тестов).
func (s *Service) Mappings() map[netip.Addr]netip.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[netip.Addr]netip.Addr{}
	for a, m := range s.maps {
		out[a] = m.Good
	}
	return out
}

// Reapply заново ставит правила всех подмен. Зовётся по SIGHUP: init-скрипт
// пересоздаёт цепочки, когда Keenetic перестраивает таблицы файрвола, и без
// этого служба считала бы подмены стоящими, а цепочки были бы пустыми.
func (s *Service) Reapply() {
	s.mu.Lock()
	s.init()
	if s.closed {
		s.mu.Unlock()
		return
	}
	type pair struct{ bad, good netip.Addr }
	var all []pair
	for a, m := range s.maps {
		all = append(all, pair{a, m.Good})
	}
	s.mu.Unlock()
	// iptables — вне s.mu (см. syncQUIC). Подмена, снятая за это время,
	// вернётся строками, но unmap снимет их по своей паре: Del идемпотентен.
	for _, p := range all {
		if err := s.Rules.Add(p.bad, p.good); err != nil {
			log.Printf("gvsub: восстановить %s → %s: %v", p.bad, p.good, err)
		}
	}
	s.syncQUIC(true)
	log.Printf("gvsub: правила восстановлены (%d)", len(all))
}

// Shutdown снимает все подмены.
func (s *Service) Shutdown() {
	s.mu.Lock()
	s.init()
	s.closed = true // идущие в фоне проверки после этого подмен не ставят
	all := s.maps
	s.maps = map[netip.Addr]*mapping{}
	s.mu.Unlock()
	s.syncQUIC(false) // closed — желаемых отказов нет, снимаются все
	for a, m := range all {
		_ = s.Rules.Del(a, m.Good)
	}
	s.writeStatus()
}

type statusFile struct {
	Updated  time.Time `json:"updated"`
	Mappings []struct {
		Bad   string    `json:"bad"`
		Good  string    `json:"good"`
		Since time.Time `json:"since"`
	} `json:"mappings"`
	Known int `json:"known"`
	Bad   int `json:"bad_seen"`
	// Адреса в ходу — для Restore после перезапуска службы.
	Addrs []knownAddr `json:"addrs,omitempty"`
}

type knownAddr struct {
	Addr string    `json:"addr"`
	Name string    `json:"name,omitempty"`
	Seen time.Time `json:"seen"`
}

// Restore поднимает адреса в ходу из файла состояния прошлого запуска.
// Устройства берут адреса из своего кэша DNS и роутер заново не спрашивают:
// без этого после перезапуска служба не знала адреса, на который ходил Mac,
// и видео стояло (10.11.2026). Вердикты не берутся — адреса проверяются
// заново на первом тике.
func (s *Service) Restore() int {
	if s.StatusPath == "" {
		return 0
	}
	b, err := os.ReadFile(s.StatusPath)
	if err != nil {
		return 0
	}
	var st statusFile
	if json.Unmarshal(b, &st) != nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.init()
	now := s.Now()
	n := 0
	for _, k := range st.Addrs {
		a, err := netip.ParseAddr(k.Addr)
		if err != nil || now.Sub(k.Seen) > IdleDrop || k.Seen.After(now) {
			continue
		}
		if s.known[a] == nil {
			s.known[a] = &entry{seen: k.Seen, name: k.Name}
			n++
		}
	}
	return n
}

func (s *Service) writeStatus() {
	if s.StatusPath == "" {
		return
	}
	s.mu.Lock()
	var st statusFile
	st.Updated = s.Now()
	st.Known = len(s.known)
	for a, e := range s.known {
		if e.verdict == Bad {
			st.Bad++
		}
		st.Addrs = append(st.Addrs, knownAddr{a.String(), e.name, e.seen})
	}
	for a, m := range s.maps {
		st.Mappings = append(st.Mappings, struct {
			Bad   string    `json:"bad"`
			Good  string    `json:"good"`
			Since time.Time `json:"since"`
		}{a.String(), m.Good.String(), m.Since})
	}
	s.mu.Unlock()
	sort.Slice(st.Mappings, func(i, j int) bool { return st.Mappings[i].Bad < st.Mappings[j].Bad })
	sort.Slice(st.Addrs, func(i, j int) bool { return st.Addrs[i].Addr < st.Addrs[j].Addr })
	b, _ := json.MarshalIndent(st, "", "  ")
	tmp := s.StatusPath + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, s.StatusPath)
	}
}

// writeIPs записывает адреса в ходу в IPFile, если набор изменился. Набор не
// чистится по вердикту: пробу движок применяет к любому адресу googlevideo, и
// на рабочем она стоит лишь задержки, а «рабочий» адрес может испортиться.
func (s *Service) writeIPs() {
	if s.IPFile == "" {
		return
	}
	s.mu.Lock()
	list := make([]string, 0, len(s.known))
	for a := range s.known {
		list = append(list, a.String())
	}
	s.mu.Unlock()
	sort.Strings(list)
	body := strings.Join(list, "\n") + "\n"
	s.ipmu.Lock()
	defer s.ipmu.Unlock()
	if body == s.ipLast {
		return
	}
	tmp := s.IPFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		log.Printf("gvsub: список адресов: %v", err)
		return
	}
	if err := os.Rename(tmp, s.IPFile); err != nil {
		log.Printf("gvsub: список адресов: %v", err)
		return
	}
	s.ipLast = body
}
