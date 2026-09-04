package main

// registry.go — Stage B per-install identity gating (Mark 2026-06-21).
//
// Each genuine z2k install mints an Ed25519 keypair on-device (private key never
// leaves the router, never in the repo/binary) and registers its public key here
// via POST /register. On tunnel connect it presents a per-install AUTH frame
// (mux type 0x06) carrying install_id + a fresh timestamp + an Ed25519 signature.
//
// This is DUAL-ACCEPT and NOT a flip: the relay still accepts the shared-secret
// HMAC (muxAUTH 0x00) as long as --require-per-install is false (the default).
// The flip — refusing static auth so only registered installs get through — is a
// separate, deliberate decision flipped via --require-per-install once adoption
// is high. Nothing here blocks any current client.

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"filippo.io/edwards25519"
)

var (
	registryPath          = flag.String("registry-path", "/var/lib/z2k-relay/registry.json", "per-install identity registry file")
	requirePerInstall     = flag.Bool("require-per-install", false, "FLIP: reject static-secret auth, require a registered per-install signature. DO NOT enable until adoption is high — it black-holes every non-migrated install.")
	perInstallMaxSessions = flag.Int("per-install-max-sessions", 64, "max concurrent tunnel sessions per install_id (0 = unlimited)")
	registerRatePerMin    = flag.Int("register-rate-per-min", 30, "max /register POSTs accepted per source IP per minute (mass-mint speed-bump)")
	authSkewSeconds       = flag.Int64("auth-skew-seconds", 120, "max accepted clock skew (seconds) on the per-install AUTH timestamp")
)

// ----------------------------------------------------------------- registry ---

type regEntry struct {
	Pubkey    string `json:"pubkey"`     // base64(std) Ed25519 public key
	Revoked   bool   `json:"revoked"`    // surgical kill-switch (checked on the auth hot path)
	CreatedAt int64  `json:"created_at"` // unix seconds
}

type registry struct {
	mu sync.RWMutex
	m  map[string]*regEntry
	// seq — номер снимка. Растёт под rg.mu, при каждом маршалинге.
	seq uint64

	// writeMu сериализует записи на диск между собой. Берётся ТОЛЬКО внутри
	// возвращённой функции, то есть уже без rg.mu — см. persistLocked.
	writeMu sync.Mutex
	// written — номер последнего снимка, легшего на диск. Только под writeMu.
	written uint64
	path    string
}

var reg *registry

func initRegistry(path string) {
	reg = &registry{m: make(map[string]*regEntry), path: path}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("registry: read %s: %v (starting empty)", path, err)
		}
		return
	}
	var m map[string]*regEntry
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("registry: parse %s: %v (starting empty)", path, err)
		return
	}
	reg.m = m
	log.Printf("registry: loaded %d install identities from %s", len(m), path)
}

// get returns a COPY of the entry, never the pointer the map holds.
//
// Returning the pointer was a data race on the one field that matters:
// setRevoked mutates e.Revoked under the write lock, while the auth hot path
// read e.Revoked and e.Pubkey after get() had already released the read lock.
// -race flags it, and in production it means a revocation may simply not be
// seen by a connection authenticating at that moment — the kill-switch failing
// exactly when it is being used. reload() has the same shape: it swaps the map
// under the lock, leaving any escaped pointer aliasing a discarded entry.
//
// The struct is three small fields, so copying costs nothing measurable on a
// path that is already doing Ed25519 verification.
func (rg *registry) get(id string) *regEntry {
	rg.mu.RLock()
	defer rg.mu.RUnlock()
	e := rg.m[id]
	if e == nil {
		return nil
	}
	cp := *e
	return &cp
}

// upsert records a new identity. Mint-once: an existing id with a DIFFERENT
// pubkey is rejected (prevents a thief re-binding someone else's install_id).
// Returns (created bool, ok bool).
func (rg *registry) upsert(id, pubkey string) (bool, bool) {
	var flush func()
	created, ok := func() (bool, bool) {
		rg.mu.Lock()
		defer rg.mu.Unlock()
		if e, exists := rg.m[id]; exists {
			if e.Pubkey != pubkey {
				return false, false // id taken by a different key — reject
			}
			return false, true // idempotent re-register
		}
		rg.m[id] = &regEntry{Pubkey: pubkey, CreatedAt: time.Now().Unix()}
		flush = rg.persistLocked()
		return true, true
	}()
	// Запись на диск — уже без rg.mu, чтобы аутентификация живых туннелей
	// не ждала ввода-вывода.
	if flush != nil {
		flush()
	}
	return created, ok
}

// setRevoked поднимает или снимает флаг отзыва и сразу сохраняет файл.
//
// До этого способа выставить флаг не существовало вовсе: поле Revoked читалось
// на горячем пути аутентификации, но записать его было нечем. Оставалось
// править registry.json руками — а это не работало дважды: до перезапуска
// правка не читалась, и первая же успешная регистрация переписывала файл из
// памяти и молча её стирала.
func (rg *registry) setRevoked(id string, v bool) bool {
	var flush func()
	found := func() bool {
		rg.mu.Lock()
		defer rg.mu.Unlock()
		e := rg.m[id]
		if e == nil {
			return false
		}
		if e.Revoked != v {
			e.Revoked = v
			flush = rg.persistLocked()
		}
		return true
	}()
	if flush != nil {
		flush()
	}
	return found
}

// reload перечитывает реестр с диска, не перезапуская релей. Перезапуск рвёт
// все живые туннели разом, поэтому ради правки одной записи он неприемлем.
//
// Записи, добавленные в памяти, но ещё не попавшие в файл, потеряться не могут:
// upsert сохраняет файл сразу же.
func (rg *registry) reload() (int, error) {
	data, err := os.ReadFile(rg.path)
	if err != nil {
		return 0, err
	}
	var m map[string]*regEntry
	if err := json.Unmarshal(data, &m); err != nil {
		return 0, err
	}
	rg.mu.Lock()
	rg.m = m
	n := len(m)
	rg.mu.Unlock()
	return n, nil
}

// revokedIDs перечисляет отозванные установки — чтобы после перечитывания файла
// оборвать их живые туннели.
func (rg *registry) revokedIDs() []string {
	rg.mu.RLock()
	defer rg.mu.RUnlock()
	out := make([]string, 0, 8)
	for id, e := range rg.m {
		if e.Revoked {
			out = append(out, id)
		}
	}
	return out
}

// persistLocked маршалит реестр ПОД замком (иначе гонка на карте), а вот
// саму запись на диск отдаёт наружу — уже без замка.
//
// Раньше здесь под эксклюзивным rg.mu делалось всё: marshal, WriteFile, Rename.
// А на том же мьютексе сидит горячий путь аутентификации (get берёт RLock).
// То есть каждая регистрация придерживала аутентификацию ВСЕХ живых туннелей
// на время синхронной записи файла целиком. При 1551 записи это доли
// миллисекунды и никого не задевает — но общий секрет публичен, а значит
// чеканка личностей доступна кому угодно: реестр растёт, запись замедляется,
// и дешёвый флуд по /register превращается в остановку аутентификации всему
// парку. Ротация секрета этого не лечит, лечит вот это разделение.
//
// Разделение было НЕПОЛНЫМ до 2026-08-14. writeMu захватывался здесь, то есть
// ещё под rg.mu, а отпускался после записи. Пока первый писатель пишет на диск,
// второй берёт rg.mu, упирается в writeMu — и держит rg.mu всё это время. За
// ним встаёт аутентификация ВСЕХ живых туннелей (get берёт RLock). То самое
// торможение, ради устранения которого разделение и вводилось, просто
// сдвинулось на одного писателя: одновременная регистрация его возвращала.
//
// Почему нельзя было просто перенести захват внутрь: writeMu под rg.mu
// гарантировал порядок — снимок, сделанный раньше, и ляжет раньше. Без него
// более старый снимок мог перезаписать более свежий.
//
// Порядок теперь держит номер снимка, а не замок. Мутация и маршалинг идут в
// одной критической секции rg.mu, поэтому снимок с бо́льшим номером заведомо
// включает всё, что вошло в меньшие. Значит устаревшую запись можно просто НЕ
// делать: на диске остаётся самый свежий снимок, а записей на флеш становится
// меньше. При ошибке записи номер не двигаем — следующая попытка обязана
// пройти.
//
// Вызывающий обязан держать rg.mu. Возвращённая функция вызывается ПОСЛЕ
// снятия замка; nil означает «писать нечего».
func (rg *registry) persistLocked() func() {
	if rg.path == "" {
		return nil
	}
	data, err := json.Marshal(rg.m)
	if err != nil {
		log.Printf("registry: marshal: %v", err)
		return nil
	}
	rg.seq++
	seq := rg.seq
	path := rg.path
	return func() {
		rg.writeMu.Lock()
		defer rg.writeMu.Unlock()
		if seq <= rg.written {
			return // более свежий снимок уже на диске — наш устарел
		}
		_ = os.MkdirAll(filepath.Dir(path), 0o700)
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, data, 0o600); err != nil {
			log.Printf("registry: write %s: %v", tmp, err)
			return
		}
		if err := os.Rename(tmp, path); err != nil {
			log.Printf("registry: rename %s: %v", path, err)
			return
		}
		rg.written = seq
	}
}

// ------------------------------------------------------- /register rate-limit ---

type ipBucket struct {
	count       int
	windowStart time.Time
}

var (
	regRateMu sync.Mutex
	regRate   = map[string]*ipBucket{}

	rateBlindMu   sync.Mutex
	rateBlindLast time.Time
	rateBlindN    int64
)

// rateBlindWarn жалуется, что настоящий адрес клиента до нас не доходит, но не
// чаще раза в минуту — иначе на потоке в тысячу туннелей журнал захлебнётся.
func rateBlindWarn() {
	rateBlindMu.Lock()
	rateBlindN++
	n := rateBlindN
	now := time.Now()
	shout := now.Sub(rateBlindLast) >= time.Minute
	if shout {
		rateBlindLast = now
		rateBlindN = 0
	}
	rateBlindMu.Unlock()
	if shout {
		log.Printf("ВНИМАНИЕ: /register видит петлевой адрес (%d запросов) — прокси не передаёт настоящий адрес клиента, ограничитель частоты отключён, иначе он запер бы весь парк", n)
	}
}

func registerRateOK(ip string) bool {
	if *registerRatePerMin <= 0 {
		return true
	}
	// Петлевой адрес здесь означает не «клиент с этой машины», а что наш
	// собственный прокси не сообщил настоящий адрес. Тогда ВЕСЬ парк ключуется
	// одной строкой, и ограничитель из «30 регистраций в минуту с адреса»
	// превращается в «30 в минуту на всех» — то есть сам запирает установки,
	// которые пытается защищать. Ровно так и было до 2026-08-05, пока caddy
	// штамповал всем X-Forwarded-For: 127.0.0.1 (замер: 1120 соединений из
	// 1120 с локальным адресом).
	//
	// Ограничитель нужен против массовой чеканки личностей с одного адреса.
	// Если адреса нет, он этой задачи не решает и решать не может, поэтому не
	// душим, а ГРОМКО жалуемся: тихий отказ здесь уже стоил месяца простоя.
	if ip == "" || ip == "127.0.0.1" || ip == "::1" {
		rateBlindWarn()
		return true
	}
	regRateMu.Lock()
	defer regRateMu.Unlock()
	now := time.Now()
	b := regRate[ip]
	if b == nil || now.Sub(b.windowStart) >= time.Minute {
		regRate[ip] = &ipBucket{count: 1, windowStart: now}
		// opportunistic GC of stale buckets
		if len(regRate) > 4096 {
			for k, v := range regRate {
				if now.Sub(v.windowStart) >= 2*time.Minute {
					delete(regRate, k)
				}
			}
		}
		return true
	}
	if b.count >= *registerRatePerMin {
		return false
	}
	b.count++
	return true
}

// -------------------------------------------------------- /register handler ---

type registerReq struct {
	InstallID string `json:"install_id"`
	Pubkey    string `json:"pubkey"` // base64(std) Ed25519 public key
}

// resolveRemoteIP извлекает адрес клиента из X-Forwarded-For.
//
// Берётся ПОСЛЕДНИЙ элемент, а не первый. Разница принципиальная: заголовок
// дописывает наш собственный прокси, добавляя то, что видит сам, в конец. Всё,
// что левее, прислал клиент — и подделать это может кто угодно одной строкой
// запроса.
//
// До 2026-08-05 брался первый элемент, то есть значение, выбранное клиентом.
// Последствия были не косметические: этим адресом ключуется ограничитель
// частоты регистраций (registerRateOK ниже), и обойти его можно было,
// подставляя случайный X-Forwarded-For на каждый запрос. Плюс в лог
// «register: new install ... from ...» писался выдуманный адрес.
//
// Последний элемент подделать нельзя — НО ТОЛЬКО ПОКА ЕГО ДЕЙСТВИТЕЛЬНО
// СТАВИТ ПРОКСИ. С 02.09.2026 (план 3) релей терминирует TLS сам, настоящий
// адрес приходит PROXY-заголовком, то есть r.RemoteAddr уже клиентский и
// X-Forwarded-For никто не дописывает. Значит «последний элемент» снова
// выбирает клиент, и одной строкой запроса он подделывает адрес в журнале,
// ключ ограничителя регистраций и (с 04.09) ключ кэша повторов подписей.
// Найдено ревью 04.09.2026.
//
// Поэтому XFF читается ТОЛЬКО когда TCP-пир петлевой, то есть запрос
// действительно пришёл через локальный прокси, который его и дописал.
func resolveRemoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			if i := lastIndexByte(xff, ','); i >= 0 {
				return trimSpace(xff[i+1:])
			}
			return trimSpace(xff)
		}
	}
	return host
}

func lastIndexByte(s string, b byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// --------------------------------------------- бюджет чеканки личностей ---
//
// Ограничитель частоты выше считает по АДРЕСУ: 30 регистраций в минуту с одного.
// Против ботнета это ничего не значит — тысяча адресов даёт тысячу бюджетов, а
// каждая чеканка раздувает реестр, который переписывается целиком при каждой
// записи. То есть дешёвый распределённый флуд превращается в остановку
// аутентификации всему парку.
//
// Здесь считается ГЛОБАЛЬНОЕ число новых установок в скользящем часе. Это не
// отсечка: молча отказывать в регистрации нельзя — так мы обрежем настоящий
// наплыв после публикации релиза. Это АЛАРМ: превышение попадает в лог один раз
// за окно, чтобы владелец увидел происходящее и решил сам.
//
// Порог с запасом над реальностью: за сутки наблюдения новых установок было 4.
var (
	mintMu       sync.Mutex
	mintWindow   time.Time
	mintCount    int
	mintAlarmed  bool
	mintAlarmPer = flag.Int("mint-alarm-per-hour", 200,
		"сколько новых установок в час считать аномалией (только запись в лог)")
)

// noteMint учитывает одну ЧЕКАНКУ (создание новой личности, не повторную
// регистрацию той же) и сообщает, надо ли поднять тревогу.
func noteMint(now time.Time) (count int, alarm bool) {
	mintMu.Lock()
	defer mintMu.Unlock()
	if now.Sub(mintWindow) >= time.Hour {
		mintWindow = now
		mintCount = 0
		mintAlarmed = false
	}
	mintCount++
	if *mintAlarmPer > 0 && mintCount >= *mintAlarmPer && !mintAlarmed {
		mintAlarmed = true
		return mintCount, true
	}
	return mintCount, false
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ip := resolveRemoteIP(r)
	if !registerRateOK(ip) {
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	// Auth: X-Z2K-Auth = hex(HMAC-SHA256(tunnelSecret, body)). Gated by the same
	// shared secret as the tunnel (dual-accept with --secret-prev). This is a
	// speed-bump, not the real gate — the rate-limit above bounds mass-minting.
	hsig := func(key string) string {
		m := hmac.New(sha256.New, []byte(key))
		m.Write(body)
		return hex.EncodeToString(m.Sum(nil))
	}
	got := r.Header.Get("X-Z2K-Auth")
	okAuth := subtle.ConstantTimeCompare([]byte(hsig(*secret)), []byte(got)) == 1
	if !okAuth && *secretPrev != "" {
		okAuth = subtle.ConstantTimeCompare([]byte(hsig(*secretPrev)), []byte(got)) == 1
	}
	// Отказы регистрации ЛОГИРУЕМ. Раньше здесь стоял молчаливый 401, и это
	// стоило дорого: когда включили --require-per-install, старые установки
	// начали отваливаться, а понять, кто именно долбится в релей — наши
	// пользователи с протухшим секретом или чужой проект, взявший наш публичный
	// бинарник, — было НЕЧЕМ. В журнале за сутки не нашлось ни одной строки об
	// отказах регистрации при десятках тысяч отвергнутых туннелей.
	//
	// install_id вытаскиваем даже из неавторизованного тела: сам по себе он не
	// секрет, а именно он отвечает на вопрос «свой или чужой» — знакомый
	// идентификатор из реестра значит наш, незнакомый значит чужой.
	if !okAuth {
		idHint := "-"
		var peek registerReq
		if json.Unmarshal(body, &peek) == nil && validInstallID(peek.InstallID) {
			if reg.get(peek.InstallID) != nil {
				idHint = peek.InstallID + " (ЗНАКОМЫЙ — есть в реестре)"
			} else {
				idHint = peek.InstallID + " (неизвестный)"
			}
		}
		log.Printf("register REJECTED: bad secret from %s install=%s", ip, idHint)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req registerReq
	if err := json.Unmarshal(body, &req); err != nil {
		log.Printf("register REJECTED: bad json from %s", ip)
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if !validInstallID(req.InstallID) {
		log.Printf("register REJECTED: bad install_id from %s", ip)
		http.Error(w, "bad install_id", http.StatusBadRequest)
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.Pubkey)
	if err != nil || !validEd25519Pubkey(pub) {
		log.Printf("register REJECTED: bad pubkey from %s install=%s", ip, req.InstallID)
		http.Error(w, "bad pubkey", http.StatusBadRequest)
		return
	}
	created, ok := reg.upsert(req.InstallID, req.Pubkey)
	if !ok {
		// Ключ разошёлся с тем, что в реестре: у клиента перевыпустилась
		// личность (снесли /opt, сбросили состояние), а install_id прежний.
		log.Printf("register REJECTED: install_id taken (pubkey mismatch) from %s install=%s", ip, req.InstallID)
		http.Error(w, "install_id taken", http.StatusConflict)
		return
	}
	if created {
		log.Printf("register: new install %s from %s", req.InstallID, ip)
		if n, alarm := noteMint(time.Now()); alarm {
			log.Printf("ВНИМАНИЕ: %d новых установок за час — похоже на массовую чеканку личностей. "+
				"Реестр растёт, а он переписывается целиком при каждой записи; "+
				"смотрите распределение адресов в сводке install-snapshot.", n)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

// validEd25519Pubkey reports whether pub is a safe Ed25519 public key: a
// canonical encoding of a point of full prime order. It rejects
//   - the wrong length,
//   - non-canonical encodings (SetBytes fails), and
//   - small-order points ([8]P == identity): all-zero, the neutral element,
//     order-2/4/8 points. A low-order key lets an attacker forge AUTH frames
//     without a private key (cofactor forgery) — the reason a zero-pubkey
//     `00112233…` must never have been accepted into the registry.
func validEd25519Pubkey(pub []byte) bool {
	if len(pub) != ed25519.PublicKeySize {
		return false
	}
	p, err := new(edwards25519.Point).SetBytes(pub)
	if err != nil {
		return false // non-canonical / not on curve
	}
	// Point has small order iff cofactor multiplication lands on the identity.
	if new(edwards25519.Point).MultByCofactor(p).Equal(edwards25519.NewIdentityPoint()) == 1 {
		return false
	}
	return true
}

// validInstallID: 16 bytes hex (32 chars), lowercase hex only.
func validInstallID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// ------------------------------------------------ per-install AUTH verify ---

// Anti-replay: the signed AUTH message is only install_id||timestamp, so a
// captured 88-byte frame is replayable for the whole ±authSkewSeconds window.
// We cache the signature of every ACCEPTED frame and reject a second sighting
// ИЗ ДРУГОГО АДРЕСА. Ключ кэша — подпись И адрес клиента.
//
// ЗАЧЕМ АДРЕС. Утверждение «клиент подписывает свежей меткой на каждом
// переподключении, поэтому настоящий коннект здесь не отвергается» неверно: на
// роутере ДВА процесса с одной установкой (:1443 Telegram и :1444 cdnbase), они
// поднимаются в одну секунду и подписывают идентичный id||ts — подпись
// побайтово совпадает. Замер 04.09.2026: 794 отказа «повтор подписи» за день,
// по 2–3 на установку, все в секунды массового переподключения после
// переключения экземпляра релея. Один из двух туннелей терял первую попытку и
// ждал бэкофф; если проигрывал :1443, человек видел лишние секунды
// «Соединение». Адрес у своих процессов один и тот же, у постороннего — чужой,
// поэтому повтор из другой сети по-прежнему отсекается.
//
// TTL спанит окно приёма (2*authSkewSeconds) — всё старше уже отсечено гейтом
// часов. Mirrors the regRate map+mutex+inline-GC.
// authIPBlind — адреса, по которым НЕЛЬЗЯ различать клиентов: петлевой (прокси
// не передал настоящий) и пустой.
func authIPBlind(ip string) bool {
	if ip == "" {
		return true
	}
	p := net.ParseIP(ip)
	return p == nil || p.IsLoopback()
}

var (
	authBlindMu   sync.Mutex
	authBlindLast time.Time
	authBlindN    int
)

// authBlindWarn — не чаще раза в минуту, как rateBlindWarn.
func authBlindWarn() {
	authBlindMu.Lock()
	authBlindN++
	n := authBlindN
	now := time.Now()
	shout := now.Sub(authBlindLast) >= time.Minute
	if shout {
		authBlindLast = now
		authBlindN = 0
	}
	authBlindMu.Unlock()
	if shout {
		log.Printf("ВНИМАНИЕ: кэш повторов видит петлевой адрес (%d кадров) — прокси не передаёт настоящий адрес клиента, дубли подписи отвергаются строго", n)
	}
}

type authSighting struct {
	ip string
	at time.Time
}

var (
	authNonceMu   sync.Mutex
	authNonceSeen = map[string]authSighting{} // key: the 64-byte signature
)

// authReplaySeen запоминает подпись вместе с адресом, с которого её приняли, и
// сообщает «это повтор» только если ту же подпись в пределах окна принесли С
// ДРУГОГО адреса. Call ONLY for cryptographically-valid frames.
func authReplaySeen(sig []byte, ip string) bool {
	ttl := time.Duration(2**authSkewSeconds) * time.Second
	authNonceMu.Lock()
	defer authNonceMu.Unlock()
	now := time.Now()
	key := string(sig)
	if e, ok := authNonceSeen[key]; ok && now.Sub(e.at) < ttl {
		// Без настоящего адреса (прокси перестал его передавать — полевой
		// случай 05.08.2026, 1120 из 1120 соединений как 127.0.0.1) правило
		// «тот же адрес — свой второй процесс» перестаёт что-либо различать:
		// весь парк сходится в один ключ. Тогда возвращаемся к строгому
		// одноразовому кадру и жалуемся в журнал, а не принимаем всё подряд.
		if authIPBlind(ip) {
			authBlindWarn()
			return true
		}
		if e.ip != ip {
			return true // тот же кадр из другой сети — повтор
		}
		return false // второй процесс той же установки
	}
	authNonceSeen[key] = authSighting{ip: ip, at: now}
	// opportunistic GC of expired entries (bounded memory, no goroutine)
	if len(authNonceSeen) > 8192 {
		for k, e := range authNonceSeen {
			if now.Sub(e.at) >= ttl {
				delete(authNonceSeen, k)
			}
		}
	}
	return false
}

// verifyPerInstallAuth parses+verifies a muxAUTHID payload:
//
//	[install_id:16][timestamp:8 BE unix][ed25519 sig:64]   (88 bytes)
//
// signed message = install_id(16) || timestamp(8). Возвращает install_id (для
// лога и квоты), прошла ли проверка, и ПРИЧИНУ отказа.
//
// Причина возвращается не для красоты. До 2026-08-05 все отказы выглядели в
// логе одинаково, и разобрать конкретный случай было нечем: у одной установки
// (зарегистрированной, не отозванной) 212 отказов подряд и ни одного успеха, а
// чем именно её отшивают — часами, подписью или чем-то ещё — приходилось
// выводить исключением по косвенным признакам. Причин ровно пять, они
// различаются одной строкой, и без неё диагностика превращается в гадание.
//
// Для расхождения часов пишется САМА величина: «на сколько ушли» — это ответ,
// а «часы не те» — только гипотеза, которую всё равно придётся проверять.
func verifyPerInstallAuth(payload []byte, clientIP string) (string, bool, string) {
	if len(payload) != 88 {
		return "", false, "кадр не 88 байт"
	}
	id := hex.EncodeToString(payload[0:16])
	ts := int64(binary.BigEndian.Uint64(payload[16:24]))
	sig := payload[24:88]
	now := time.Now().Unix()
	if ts < now-*authSkewSeconds || ts > now+*authSkewSeconds {
		skew := ts - now
		return id, false, fmt.Sprintf("часы разошлись на %+ds (допуск ±%ds)", skew, *authSkewSeconds)
	}
	e := reg.get(id)
	if e == nil {
		return id, false, "установка не зарегистрирована"
	}
	if e.Revoked {
		return id, false, "установка отозвана"
	}
	pub, err := base64.StdEncoding.DecodeString(e.Pubkey)
	if err != nil || !validEd25519Pubkey(pub) {
		// Defense in depth: a low-order key must never authenticate even if it
		// slipped into the registry before validEd25519Pubkey gated /register.
		return id, false, "в реестре негодный публичный ключ"
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), payload[0:24], sig) {
		// Ключ на устройстве разошёлся с тем, что записан у нас. Лечится только
		// перевыпуском личности: клиент получает 409 на регистрации и заводит
		// новую. Если этого не происходит — регистрация до нас не доходит.
		return id, false, "подпись не сходится с ключом в реестре"
	}
	if authReplaySeen(sig, clientIP) {
		return id, false, "повтор подписи"
	}
	return id, true, ""
}

// verifyPerInstallAuthV2 — подпись над id||ts||nonce; nonce одноразовый на
// сессию, поэтому replay-кэш не нужен и два коннекта в одну секунду не
// конфликтуют (спека §2.4). Возвращает ещё и код причины для INFO GOODBYE.
func verifyPerInstallAuthV2(a authV2, nonce [16]byte) (string, bool, string, byte) {
	if a.Nonce != nonce {
		return a.ID, false, "nonce не совпал", rAuthFailed
	}
	// ЧАСЫ В V2 НЕ ОТВЕРГАЮТ ВХОД. От повтора здесь защищает nonce: он выдан
	// сервером на это соединение и проверен выше, поэтому перехваченный кадр
	// не подойдёт ни к какому другому. Метка времени осталась в подписи только
	// как совет клиенту (INFO CLOCK_SKEW после AUTH_OK).
	//
	// Раньше тут стоял тот же гейт ±120 с, что и в v1, и он выключал людей
	// целиком: роутеры без работающего NTP получали отказ на каждой попытке —
	// замер 02–04.09.2026: 10 установок, 4430 отказов, у одной часы врут на
	// 31,6 ч и туннель не поднялся ни разу за двое суток. В v1 метка времени
	// действительно единственная защита от повтора, поэтому там гейт остаётся.
	e := reg.get(a.ID)
	if e == nil {
		return a.ID, false, "установка не зарегистрирована", rAuthFailed
	}
	if e.Revoked {
		return a.ID, false, "установка отозвана", rRevoked
	}
	pub, err := base64.StdEncoding.DecodeString(e.Pubkey)
	if err != nil || !validEd25519Pubkey(pub) {
		return a.ID, false, "в реестре негодный публичный ключ", rAuthFailed
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), a.Signed, a.Sig) {
		return a.ID, false, "подпись не сходится с ключом в реестре", rAuthFailed
	}
	return a.ID, true, "", rNormal
}

// ------------------------------------------------ per-install session quota ---

// Квота живёт в общем учёте по установкам (installstats.go). Раньше здесь была
// отдельная sync.Map со счётчиком: она ничего не знала ни об адресах, ни о
// трафике, ни о самих соединениях (то есть отозвать по ней было нечего) и
// НИКОГДА не вычищалась — запись оставалась навсегда после первой же сессии.

func acquireInstallSession(id, ip string, s *session) (bool, string) {
	return installs.begin(id, ip, s)
}

func releaseInstallSession(id string, s *session, rx, tx int64) {
	installs.end(id, s, rx, tx)
}

// tiny helpers (avoid importing strings just for these)
func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}
