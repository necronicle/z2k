package sniwl

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"
)

// Умолчания менеджера.
const (
	// DefaultNetCooldown — сеть характеризуется ОДИН раз, повтор не чаще
	// суток. Проба стоит ~40 КБ аплинка на имя и секунды времени; на этом
	// фоне «раз в сутки» — это уже щедро.
	DefaultNetCooldown = 24 * time.Hour
	// DefaultQueueSize — глубина очереди наблюдений. Переполнение = дроп,
	// а не ожидание: главный цикл демона блокировать нельзя ни на такт.
	DefaultQueueSize = 64
	// DefaultWorkers — параллельных ХАРАКТЕРИЗАЦИЙ. Одна: внутри неё уже
	// сидит батч на четыре пробы, и вторая сеть одновременно означала бы
	// восемь живых TLS-сессий на двухъядерном роутере.
	DefaultWorkers = 1
	// DefaultResolveTimeout — на резолв домена из очереди.
	DefaultResolveTimeout = 3 * time.Second
)

// Вердикты по сети. Хранятся в памяти; на диске живёт только положительный
// (файл сетей), и он же восстанавливается при старте.
const (
	verdictAffected = "affected"
	verdictClean    = "clean"
	// verdictNoName — сеть режет, список исчерпан, переконтроль воспроизвёлся.
	// Достоверный минус: сутки не трогаем.
	verdictNoName = "affected_no_name"
	// verdictUnmeasured — контроль не состоялся, мерить было нечем.
	verdictUnmeasured = "unmeasured"
	// verdictInconclusive — перебор прошёл, но контроль по дороге
	// деградировал. Минус недостоверен: сеть надо померить заново — не
	// сейчас, а после кулдауна, потому что долбить адрес, который перестал
	// нам отвечать, значит гарантированно получить тот же ответ.
	verdictInconclusive = "inconclusive"
)

// Config — конфигурация подсистемы подбора.
type Config struct {
	// Enabled — выключено значит не создавать менеджер вовсе.
	Enabled        bool
	CandidatesPath string
	NetworksPath   string
	NamePath       string
	Sweep          SweepConfig
	NetCooldown    time.Duration
	QueueSize      int
	Workers        int
	ResolveTimeout time.Duration

	// Resolve — nil означает системный резолвер. Инъекция для тестов.
	Resolve func(ctx context.Context, domain string) ([]string, error)
	// Now — nil означает time.Now. Инъекция для тестов троттлинга.
	Now func() time.Time
	// Logf — nil означает log.Printf.
	Logf func(format string, a ...any)
}

// Defaults — боевая конфигурация.
func Defaults() Config {
	return Config{
		Enabled:        true,
		CandidatesPath: DefaultCandidatesPath,
		NetworksPath:   DefaultNetworksPath,
		NamePath:       DefaultNamePath,
		Sweep:          SweepConfig{}.WithDefaults(),
		NetCooldown:    DefaultNetCooldown,
		QueueSize:      DefaultQueueSize,
		Workers:        DefaultWorkers,
		ResolveTimeout: DefaultResolveTimeout,
	}
}

func (c Config) withDefaults() Config {
	if c.CandidatesPath == "" {
		c.CandidatesPath = DefaultCandidatesPath
	}
	if c.NetCooldown <= 0 {
		c.NetCooldown = DefaultNetCooldown
	}
	if c.QueueSize <= 0 {
		c.QueueSize = DefaultQueueSize
	}
	if c.Workers <= 0 {
		c.Workers = DefaultWorkers
	}
	if c.ResolveTimeout <= 0 {
		c.ResolveTimeout = DefaultResolveTimeout
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Logf == nil {
		c.Logf = log.Printf
	}
	if c.Resolve == nil {
		c.Resolve = defaultResolve(c.ResolveTimeout)
	}
	c.Sweep = c.Sweep.WithDefaults()
	return c
}

// Stats — счётчики для триажа и вебморды.
type Stats struct {
	Offered  int `json:"offered"`
	Dropped  int `json:"dropped"`
	Swept    int `json:"swept"`
	Affected int `json:"affected"`
	Clean    int `json:"clean"`
	// Unmeasured — прогонов, где не состоялся контроль.
	Unmeasured int `json:"unmeasured"`
	// Inconclusive — прогонов, где перебор кончился без имени, а контроль
	// по дороге деградировал. Это НЕ «имени нет», это «мы не узнали».
	Inconclusive int    `json:"inconclusive"`
	Published    int    `json:"published"`
	Networks     int    `json:"networks"`
	Name         string `json:"name,omitempty"`
}

type netEntry struct {
	verdict string
	at      time.Time
}

type job struct {
	domain string
	ips    []string
}

// Manager ведёт очередь наблюдений, дедуп и троттлинг по СЕТЯМ и пишет два
// файла состояния.
//
// Дисциплина скопирована с engine.state, но ключ у неё другой. У движка
// единица — домен, у нас — сеть /16: коробка привязана к сети назначения, и
// это замерено (согласие вердиктов 81.3% на 412 сетях). Поэтому и ручки свои:
// проба тянет десятки килобайт и живёт секунды, ей нельзя в общий семафор на
// восемь — это ровно тот шторм, которого просили избежать.
type Manager struct {
	cfg   Config
	store Store
	cands []Candidate

	queue chan job

	mu       sync.Mutex
	nets     map[uint32]netEntry
	inflight map[uint32]struct{}
	domains  map[string]time.Time
	stats    Stats
}

// New поднимает менеджер: читает кандидатов и восстанавливает уже известные
// сети из файла.
//
// Известные сети получают отметку времени СТАРТА, а не нулевую. Иначе каждый
// перезапуск демона (а его перезапускает и обновление, и OOM-сторож) начинал
// бы перепроверку всех опубликованных сетей разом — то есть перезапуск сам по
// себе становился бы источником трафика.
func New(cfg Config) (*Manager, error) {
	cfg = cfg.withDefaults()
	cands, err := LoadCandidates(cfg.CandidatesPath)
	if err != nil {
		return nil, err
	}
	st := NewStore(cfg.NetworksPath, cfg.NamePath)
	// Часовой — первым делом. Файл мог пережить чистку руками или обрыв
	// записи, а он уже скормлен работающему nfqws2: файл без часового,
	// оставшись пустым, снимает с профиля фильтр целиком (см. SentinelNet).
	if fixed, err := st.EnsureSentinel(); err != nil {
		cfg.Logf("sniwl: %s: часового дописать не вышло: %v", st.NetworksPath, err)
	} else if fixed {
		cfg.Logf("sniwl: %s: дописан часовой %s — без него пустой файл означал бы ipset без фильтра",
			st.NetworksPath, SentinelNet)
	}
	known, err := st.LoadNetworks()
	if err != nil {
		return nil, fmt.Errorf("sniwl: %s: %w", st.NetworksPath, err)
	}
	m := &Manager{
		cfg:      cfg,
		store:    st,
		cands:    cands,
		queue:    make(chan job, cfg.QueueSize),
		nets:     make(map[uint32]netEntry, len(known)),
		inflight: make(map[uint32]struct{}),
		domains:  make(map[string]time.Time),
	}
	now := cfg.Now()
	for k := range known {
		m.nets[k] = netEntry{verdict: verdictAffected, at: now}
	}
	m.stats.Networks = len(known)
	m.stats.Name, _ = st.LoadName()
	return m, nil
}

// Candidates отдаёт разобранный список — для CLI и отчётов.
func (m *Manager) Candidates() []Candidate { return m.cands }

// Stats — снимок счётчиков.
func (m *Manager) Stats() Stats {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.stats
	return s
}

// Offer ставит домен в очередь на характеризацию его сети.
//
// НЕ БЛОКИРУЕТ И НЕ ХОДИТ В СЕТЬ: вызывается прямо из главного цикла демона,
// поэтому здесь только карта и неблокирующая запись в канал. ips могут быть
// пустыми — тогда резолвить будет рабочая горутина, а не главный цикл.
//
// Дроп при переполнении очереди НЕ сжигает кулдаун домена: слот отдаётся
// обратно. Это та же ошибка, что уже была починена в движке — там дропнутое
// по семафору наблюдение молчало полный ProbeCooldown, и домен замечался не с
// первой перезагрузки страницы, а через пять минут.
func (m *Manager) Offer(domain string, ips []string) {
	if m == nil || domain == "" {
		return
	}
	now := m.cfg.Now()
	m.mu.Lock()
	m.stats.Offered++
	if last, ok := m.domains[domain]; ok && now.Sub(last) < m.cfg.NetCooldown {
		m.stats.Dropped++
		m.mu.Unlock()
		return
	}
	m.domains[domain] = now
	m.mu.Unlock()

	select {
	case m.queue <- job{domain: domain, ips: ips}:
	default:
		m.mu.Lock()
		delete(m.domains, domain)
		m.stats.Dropped++
		m.mu.Unlock()
	}
}

// Run запускает рабочие горутины и блокируется до отмены контекста.
func (m *Manager) Run(ctx context.Context) {
	var wg sync.WaitGroup
	for i := 0; i < m.cfg.Workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m.worker(ctx)
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		m.evictLoop(ctx)
	}()
	wg.Wait()
}

func (m *Manager) worker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case j := <-m.queue:
			m.handle(ctx, j)
		}
	}
}

func (m *Manager) handle(ctx context.Context, j job) {
	ips := j.ips
	if len(ips) == 0 {
		var err error
		ips, err = m.cfg.Resolve(ctx, j.domain)
		if err != nil || len(ips) == 0 {
			return
		}
	}
	ip, key, ok := FirstRoutable(ips)
	if !ok {
		return
	}
	if !m.claim(key) {
		return
	}
	defer m.release(key)

	addr := net.JoinHostPort(ip, "443")
	incumbent, err := m.store.LoadName()
	if err != nil {
		m.cfg.Logf("sniwl: %s: %v", m.store.NamePath, err)
	}
	cands := OrderWithIncumbent(m.cands, incumbent)
	res := RunSweep(ctx, addr, cands, m.cfg.Sweep)
	res.Network = CIDR(key)
	m.apply(res, key, j.domain, incumbent)
}

// apply разносит исход перебора по счётчикам и по файлам.
//
// ПОРЯДОК ЗАПИСИ ЖЁСТКИЙ: сперва имя, потом сеть. Генератор конфига гейтит
// профиль по НЕПУСТОМУ файлу сетей, а имя подставляет в фейк. Появись сеть
// раньше имени — окно, в котором профиль уже собирается, а подставлять нечего.
func (m *Manager) apply(res SweepResult, key uint32, domain, incumbent string) {
	now := m.cfg.Now()
	m.mu.Lock()
	m.stats.Swept++
	m.mu.Unlock()

	switch res.State {
	case StateCancelled:
		// Гасят демона. Это про нас, а не про сеть: отметку не ставим,
		// иначе отмена сожгла бы сети сутки кулдауна ни за что.
		return
	case StateUnmeasured:
		m.mark(key, verdictUnmeasured, now)
		m.mu.Lock()
		m.stats.Unmeasured++
		m.mu.Unlock()
		m.cfg.Logf("sniwl: %s (%s, по домену %s): измерить не удалось — %s",
			res.Network, res.Addr, domain, res.Reason)
		return
	case StateClean, StateNoise:
		m.mark(key, verdictClean, now)
		m.mu.Lock()
		m.stats.Clean++
		m.mu.Unlock()
		return
	case StateInconclusive:
		// Список кончился без имени, но контроль по дороге деградировал:
		// последние пробы были не про имена. Ни публиковать, ни записывать
		// «имени нет» нельзя — это ровно та выдуманная уверенность, ради
		// которой в classify заведён VerdictInconclusive.
		m.mark(key, verdictInconclusive, now)
		m.mu.Lock()
		m.stats.Inconclusive++
		m.mu.Unlock()
		m.cfg.Logf("sniwl: %s (%s, по домену %s): результат неубедителен — %s",
			res.Network, res.Addr, domain, res.Reason)
		return
	case StateNoName:
		// Сеть режет, но ни одно имя не пробило, и переконтроль это
		// подтвердил. Публиковать её НЕЛЬЗЯ: профиль подставил бы имя, про
		// которое здесь уже известно, что оно не работает, и мы получили бы
		// фейковый пакет без выигрыша.
		m.mark(key, verdictNoName, now)
		m.mu.Lock()
		m.stats.Affected++
		m.mu.Unlock()
		m.cfg.Logf("sniwl: %s (%s, по домену %s): режет на %d байт, но имя не найдено из %d проб",
			res.Network, res.Addr, domain, res.Baseline.UplinkBytes, res.Tried)
		return
	case StateFound:
	default:
		// Неизвестное состояние — молчим и ничего не публикуем.
		m.cfg.Logf("sniwl: %s (%s, по домену %s): неизвестное состояние прогона %q — %s",
			res.Network, res.Addr, domain, res.State, res.Reason)
		return
	}

	detail := fmt.Sprintf("%s | контроль оборван на %d Б | имя %s (строка %d) прошло %d кусков | домен %s",
		res.Network, res.Baseline.UplinkBytes, res.Winner, res.WinnerLine, m.cfg.Sweep.Probe.Chunks, domain)

	if res.Winner != incumbent {
		// Действующее имя пробовалось ПЕРВЫМ (OrderWithIncumbent), значит
		// смена происходит только когда оно на этой сети перестало
		// работать. Меняем и говорим об этом громко: ранее опубликованные
		// сети проверялись со старым именем, и если новое им не подойдёт,
		// они просто перестанут выигрывать — хуже, чем было, не станет,
		// но знать об этом надо.
		if err := m.store.SetName(res.Winner, detail); err != nil {
			m.cfg.Logf("sniwl: запись имени %s: %v", m.store.NamePath, err)
			m.mark(key, verdictNoName, now)
			return
		}
		if incumbent == "" {
			m.cfg.Logf("sniwl: имя выбрано: %s (строка %d)", res.Winner, res.WinnerLine)
		} else {
			m.cfg.Logf("sniwl: имя СМЕНЕНО %s → %s: прежнее на сети %s не прошло",
				incumbent, res.Winner, res.Network)
		}
		m.mu.Lock()
		m.stats.Name = res.Winner
		m.mu.Unlock()
	}

	added, err := m.store.AddNetwork(key, detail)
	if err != nil {
		m.cfg.Logf("sniwl: запись сети %s: %v", m.store.NetworksPath, err)
		m.mark(key, verdictNoName, now)
		return
	}
	m.mark(key, verdictAffected, now)
	m.mu.Lock()
	m.stats.Affected++
	if added {
		m.stats.Published++
		m.stats.Networks++
	}
	m.mu.Unlock()
	if added {
		m.cfg.Logf("sniwl: %s → %s (имя %s, домен %s, контроль встал на %d Б)",
			res.Network, m.store.NetworksPath, res.Winner, domain, res.Baseline.UplinkBytes)
	}
}

// claim атомарно проверяет право мерить сеть и берёт её в работу.
// Слитно, а не двумя вызовами: между «можно» и «взял» второй рабочий успел бы
// взять ту же сеть.
func (m *Manager) claim(key uint32) bool {
	now := m.cfg.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, busy := m.inflight[key]; busy {
		return false
	}
	if e, ok := m.nets[key]; ok && now.Sub(e.at) < m.cfg.NetCooldown {
		return false
	}
	m.inflight[key] = struct{}{}
	return true
}

func (m *Manager) release(key uint32) {
	m.mu.Lock()
	delete(m.inflight, key)
	m.mu.Unlock()
}

func (m *Manager) mark(key uint32, verdict string, at time.Time) {
	m.mu.Lock()
	m.nets[key] = netEntry{verdict: verdict, at: at}
	m.mu.Unlock()
}

// Verdict отдаёт запомненный вердикт по сети — для тестов и триажа.
func (m *Manager) Verdict(key uint32) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.nets[key]
	return e.verdict, ok
}

// evictLoop подметает карту доменов. Сама карта сетей не растёт: сетей /16
// в природе 65536, а увиденных за месяц — сотни. А вот доменов домашняя сеть
// перебирает десятки тысяч в месяц, и Go-карта после delete не ужимается,
// поэтому пик остаётся навсегда.
func (m *Manager) evictLoop(ctx context.Context) {
	every := m.cfg.NetCooldown
	if every > time.Hour {
		every = time.Hour
	}
	if every < time.Minute {
		every = time.Minute
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.evict()
		}
	}
}

// evict удаляет протухшие отметки доменов. Вынесено из цикла, чтобы
// проверяться без часов.
func (m *Manager) evict() int {
	now := m.cfg.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for d, at := range m.domains {
		if now.Sub(at) >= m.cfg.NetCooldown {
			delete(m.domains, d)
			n++
		}
	}
	return n
}

func defaultResolve(timeout time.Duration) func(context.Context, string) ([]string, error) {
	return func(ctx context.Context, domain string) ([]string, error) {
		c, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		// v4-only: и маршрутизация шлюза, и боевой ipset у нас четвёртые.
		ips, err := net.DefaultResolver.LookupIP(c, "ip4", domain)
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(ips))
		for _, ip := range ips {
			out = append(out, ip.String())
		}
		return out, nil
	}
}
