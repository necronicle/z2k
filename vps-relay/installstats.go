package main

// Учёт по установкам: кто подключается, откуда и сколько.
//
// Защищаемся мы не от человека, который не заплатил, а от того, кто встроит наш
// релей в свой продукт и начнёт раздавать туннель дальше. У такого одна
// установка обслуживает много людей, то есть с ОДНОГО install_id идут
// подключения с множества разных адресов. Это и есть отличительный признак:
// домашний роутер — один адрес, изредка два, когда провайдер сменил.
//
// Замер по живому логу за три часа (636 установок): максимум разных адресов у
// одной установки — 2; в потолок одновременных сессий (64) не упёрся никто ни
// разу. То есть нормальное поведение сидит далеко от любых порогов, а чужой
// продукт на сотню пользователей вылезет за них сразу.
//
// Раньше в релее из всего этого не было ничего. Жил единственный счётчик
// одновременных сессий (sync.Map в registry.go), он никуда не сохранялся и из
// карты НИКОГДА не вычищался — то есть заодно тёк. Здесь он заменён на общий
// учёт, и записи убираются по простою.

import (
	"flag"
	"log"
	"sort"
	"sync"
	"time"
)

var (
	installSnapshotInterval = flag.Duration("install-snapshot-interval", 10*time.Minute,
		"как часто писать в лог сводку по установкам (0 = не писать)")
	// Порог наблюдения, а не отсечки. Замер за три часа дал максимум 2 адреса
	// на установку; 12 — запас с большим отрывом, чтобы мобильный интернет со
	// сменой адреса не сыпал в лог зря. Тот, кто раздаёт туннель дальше, идёт
	// не на единицы, а на сотни адресов, и порог его не спасает.
	installWarnIPs = flag.Int("install-warn-ips", 12,
		"сколько разных адресов за сутки у одной установки считать подозрительным (только запись в лог)")
	installMaxIPs = flag.Int("install-max-ips", 0,
		"жёсткий потолок разных адресов за сутки: новые сессии отвергаются (0 = выключено)")
	installSnapshotTop = flag.Int("install-snapshot-top", 8,
		"сколько установок показывать в сводке")
)

// Карта адресов у одной установки ограничена: без потолка тот, от кого мы
// защищаемся, раздул бы нам память простой ротацией адресов. Порог отсечки
// (единицы) на два порядка ниже этого предела, так что на решение ограничение
// не влияет — счётчик просто перестаёт расти дальше.
const maxTrackedIPs = 256

type installStat struct {
	day       int64 // номер суток, за которые ведутся счётчики
	live      int64 // сессий прямо сейчас
	peak      int64 // пик одновременных за сутки
	sessions  int64 // сессий открыто за сутки
	rejected  int64 // попыток, отбитых потолком, за сутки
	rx, tx    int64 // байт за сутки
	firstSeen int64
	lastSeen  int64
	ips       map[string]int64 // адрес -> когда виден последний раз
	ipsCapped bool             // упёрлись в maxTrackedIPs
	warned    bool             // о превышении порога уже написали в этих сутках

	// Живые сессии этой установки — нужны, чтобы отзыв обрывал уже поднятые
	// туннели, а не ждал, пока они отвалятся сами.
	conns map[*session]struct{}
}

type installTracker struct {
	mu sync.Mutex
	m  map[string]*installStat
}

var installs = &installTracker{m: map[string]*installStat{}}

func dayOf(t time.Time) int64 { return t.Unix() / 86400 }

// rollLocked обнуляет суточные счётчики при смене суток. Живое число сессий и
// список соединений НЕ трогаются: они описывают текущий момент, а не сутки.
func (st *installStat) rollLocked(day int64) {
	if st.day == day {
		return
	}
	st.day = day
	st.peak = st.live
	st.sessions = 0
	st.rejected = 0
	st.rx, st.tx = 0, 0
	st.ips = map[string]int64{}
	st.ipsCapped = false
	st.warned = false
}

// begin отмечает начало сессии и решает, пускать ли её. Второе значение —
// причина отказа, для лога.
//
// Оба потолка проверяются здесь, под общим замком, а не отдельным запросом
// «сколько сейчас сессий» с последующим инкрементом: между такой проверкой и
// инкрементом успевают проскочить соседние соединения, и потолок протекает
// ровно тогда, когда он нужен — при наплыве.
func (t *installTracker) begin(id, ip string, s *session) (bool, string) {
	if id == "" {
		return true, ""
	}
	now := time.Now()
	day := dayOf(now)

	t.mu.Lock()
	defer t.mu.Unlock()

	st := t.m[id]
	if st == nil {
		st = &installStat{
			day:       day,
			firstSeen: now.Unix(),
			ips:       map[string]int64{},
			conns:     map[*session]struct{}{},
		}
		t.m[id] = st
	}
	st.rollLocked(day)
	// Отметку «виден» ставим ДО проверки потолков. Иначе запись установки,
	// которая только и делает, что долбится в потолок, не обновляется вовсе, и
	// уборщик сносит её через час вместе со всеми уликами.
	st.lastSeen = now.Unix()

	if ip != "" {
		if _, known := st.ips[ip]; known || !st.ipsCapped {
			if !known && len(st.ips) >= maxTrackedIPs {
				st.ipsCapped = true
			} else {
				st.ips[ip] = now.Unix()
			}
		}
	}

	// Адрес записан ДО отказа намеренно: даже отвергнутая попытка — улика, и
	// счётчик разных адресов должен её видеть.
	if *installMaxIPs > 0 && len(st.ips) > *installMaxIPs {
		st.rejected++
		return false, "потолок разных адресов за сутки"
	}
	if *perInstallMaxSessions > 0 && st.live >= int64(*perInstallMaxSessions) {
		st.rejected++
		return false, "потолок одновременных сессий"
	}

	st.live++
	st.sessions++
	if st.live > st.peak {
		st.peak = st.live
	}
	if s != nil {
		st.conns[s] = struct{}{}
	}

	if !st.warned && *installWarnIPs > 0 && len(st.ips) >= *installWarnIPs {
		st.warned = true
		log.Printf("install %s: %d разных адресов за сутки (сессий %d, пик %d) — похоже на раздачу дальше",
			id, len(st.ips), st.sessions, st.peak)
	}
	return true, ""
}

// end отмечает конец сессии и добавляет её объём к суточному.
func (t *installTracker) end(id string, s *session, rx, tx int64) {
	if id == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	st := t.m[id]
	if st == nil {
		return
	}
	if st.live > 0 {
		st.live--
	}
	st.rx += rx
	st.tx += tx
	st.lastSeen = time.Now().Unix()
	if s != nil {
		delete(st.conns, s)
	}
}

// killInstall обрывает все живые сессии установки. Возвращает, сколько оборвал.
//
// Без этого отзыв не работал: флаг Revoked проверялся только при поднятии НОВОЙ
// сессии, а уже поднятый туннель жил, пока не отвалится сам, — то есть часами.
func (t *installTracker) killInstall(id string) int {
	t.mu.Lock()
	victims := make([]*session, 0, 8)
	if st := t.m[id]; st != nil {
		for s := range st.conns {
			victims = append(victims, s)
		}
	}
	t.mu.Unlock()

	// kill() снаружи замка: он закрывает сокет и ходит по потокам сессии, а
	// держать общий замок учёта на это время значит подвесить весь релей.
	for _, s := range victims {
		s.kill()
	}
	return len(victims)
}

// gc убирает установки, которые давно не подключались. Раньше карта счётчиков
// не чистилась вовсе и росла всё время работы процесса.
func (t *installTracker) gc(idle time.Duration) int {
	cutoff := time.Now().Add(-idle).Unix()
	t.mu.Lock()
	defer t.mu.Unlock()
	n := 0
	for id, st := range t.m {
		if st.live == 0 && len(st.conns) == 0 && st.lastSeen < cutoff {
			delete(t.m, id)
			n++
		}
	}
	return n
}

type installSnap struct {
	ID        string
	FirstSeen int64
	IPs       int
	Capped    bool
	Live      int64
	Peak      int64
	Sessions  int64
	Rejected  int64
	Bytes     int64
}

// snapshot отдаёт общий итог и самые заметные установки.
//
// Отдельная сводка нужна потому, что строка закрытия сессии показывает только
// тех, кто отключился: за 25 минут в лог попали 4 установки из 1226 живых
// туннелей. Тот, кто раздаёт туннель дальше и держит его сутками, в такой лог
// не попадёт вообще — а именно он нам и нужен.
func (t *installTracker) snapshot(top int) (total int, live int64, list []installSnap) {
	t.mu.Lock()
	defer t.mu.Unlock()
	list = make([]installSnap, 0, len(t.m))
	for id, st := range t.m {
		live += st.live
		list = append(list, installSnap{
			ID: id, FirstSeen: st.firstSeen, IPs: len(st.ips), Capped: st.ipsCapped,
			Live: st.live, Peak: st.peak, Sessions: st.sessions,
			Rejected: st.rejected, Bytes: st.rx + st.tx,
		})
	}
	total = len(list)
	// Сортируем по числу адресов — это признак раздачи. Дальше по пику сессий
	// и объёму, чтобы при равенстве наверх выходил самый нагруженный.
	sort.Slice(list, func(i, j int) bool {
		if list[i].IPs != list[j].IPs {
			return list[i].IPs > list[j].IPs
		}
		if list[i].Peak != list[j].Peak {
			return list[i].Peak > list[j].Peak
		}
		return list[i].Bytes > list[j].Bytes
	})
	if top > 0 && len(list) > top {
		list = list[:top]
	}
	return total, live, list
}

// snapshotLoop ведёт уборку и пишет сводку в лог. Останавливается по stop.
//
// Уборка идёт СВОИМ ходом, а не вместе со сводкой: иначе выключение сводки
// (--install-snapshot-interval=0) заодно выключало бы очистку, и карта
// счётчиков снова росла бы всё время работы процесса — ровно та утечка, ради
// которой этот учёт и переписан.
func (t *installTracker) snapshotLoop(every time.Duration, stop <-chan struct{}) {
	gcTick := time.NewTicker(time.Hour)
	defer gcTick.Stop()

	var snapC <-chan time.Time
	if every > 0 {
		tk := time.NewTicker(every)
		defer tk.Stop()
		snapC = tk.C
	}

	for {
		select {
		case <-stop:
			return
		case <-gcTick.C:
			if n := t.gc(48 * time.Hour); n > 0 && *verbose {
				log.Printf("install stats: убрано %d давно молчащих установок", n)
			}
		case <-snapC:
			total, live, list := t.snapshot(*installSnapshotTop)
			log.Printf("install summary: установок %d, сессий сейчас %d", total, live)
			for _, e := range list {
				capped := ""
				if e.Capped {
					capped = "+"
				}
				log.Printf("  %s ips=%d%s live=%d peak=%d sess=%d rej=%d mb=%.1f",
					e.ID, e.IPs, capped, e.Live, e.Peak, e.Sessions, e.Rejected,
					float64(e.Bytes)/1048576)
			}
		}
	}
}
