package main

// Служебный интерфейс: посмотреть, кто сколько занимает, и отрезать наглого.
//
// Отдельный слушатель, а не путь на основном — принципиально. Основной висит на
// 127.0.0.1:8080, и caddy проксирует на него ВСЁ подряд
// (`reverse_proxy localhost:8080`, без разбора путей). Любой /admin/... на нём
// оказался бы доступен из интернета вместе с туннелем.
//
// Слушатель обязан быть петлевым, это проверяется при старте: ошибка в адресе
// здесь означала бы выставленный наружу отзыв чужих установок. Снаружи ходить —
// через проброс порта по SSH.

import (
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/pprof"
	"time"
)

var (
	adminAddr = flag.String("admin-addr", "",
		"адрес служебного интерфейса, только петлевой (пусто = выключен)")
	adminToken = flag.String("admin-token", "",
		"если задан, требуется заголовок X-Z2K-Admin с этим значением")
)

func adminAuthOK(r *http.Request) bool {
	if *adminToken == "" {
		return true
	}
	return subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Z2K-Admin")), []byte(*adminToken)) == 1
}

// requireID достаёт install_id и проверяет его формат тем же правилом, что и
// регистрация: иначе опечатка молча «отзовёт» несуществующую установку.
func requireID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.URL.Query().Get("id")
	if !validInstallID(id) {
		http.Error(w, "нужен параметр id: 32 шестнадцатеричных символа", http.StatusBadRequest)
		return "", false
	}
	return id, true
}

type adminInstallsResp struct {
	Total    int           `json:"total"`
	LiveNow  int64         `json:"live_now"`
	WarnIPs  int           `json:"warn_ips"`
	MaxIPs   int           `json:"max_ips"`
	MaxSess  int           `json:"max_sessions"`
	Installs []installSnap `json:"installs"`
}

func newAdminMux() *http.ServeMux {
	mux := http.NewServeMux()

	// Метрики и pprof: порт слушает только 127.0.0.1, наружу не виден.
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		metrics.write(w)
	})
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	// Сводка. По умолчанию показывает всех: замер важнее краткости, а число
	// установок здесь измеряется сотнями, не миллионами.
	mux.HandleFunc("/admin/installs", func(w http.ResponseWriter, r *http.Request) {
		if !adminAuthOK(r) {
			http.Error(w, "нет доступа", http.StatusForbidden)
			return
		}
		top := 0
		if v := r.URL.Query().Get("top"); v != "" {
			_, _ = fmt.Sscanf(v, "%d", &top)
		}
		total, live, list := installs.snapshot(top)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminInstallsResp{
			Total: total, LiveNow: live,
			WarnIPs: *installWarnIPs, MaxIPs: *installMaxIPs,
			MaxSess:  *perInstallMaxSessions,
			Installs: list,
		})
	})

	// Отзыв: поднять флаг, сохранить файл И оборвать живые туннели. Без
	// последнего отзыв откладывался до того, как установка отвалится сама.
	mux.HandleFunc("/admin/revoke", func(w http.ResponseWriter, r *http.Request) {
		if !adminAuthOK(r) {
			http.Error(w, "нет доступа", http.StatusForbidden)
			return
		}
		id, ok := requireID(w, r)
		if !ok {
			return
		}
		if !reg.setRevoked(id, true) {
			http.Error(w, "установка не найдена", http.StatusNotFound)
			return
		}
		n := installs.killInstall(id)
		log.Printf("admin: установка %s отозвана, оборвано живых сессий: %d", id, n)
		fmt.Fprintf(w, "отозвана %s, оборвано сессий: %d\n", id, n)
	})

	mux.HandleFunc("/admin/unrevoke", func(w http.ResponseWriter, r *http.Request) {
		if !adminAuthOK(r) {
			http.Error(w, "нет доступа", http.StatusForbidden)
			return
		}
		id, ok := requireID(w, r)
		if !ok {
			return
		}
		if !reg.setRevoked(id, false) {
			http.Error(w, "установка не найдена", http.StatusNotFound)
			return
		}
		log.Printf("admin: с установки %s снят отзыв", id)
		fmt.Fprintf(w, "снят отзыв с %s\n", id)
	})

	// Перечитать реестр с диска — на случай правки файла руками. Сразу же
	// обрываем живые сессии всех отозванных: иначе правка вступит в силу
	// только для новых подключений.
	mux.HandleFunc("/admin/reload", func(w http.ResponseWriter, r *http.Request) {
		if !adminAuthOK(r) {
			http.Error(w, "нет доступа", http.StatusForbidden)
			return
		}
		n, err := reg.reload()
		if err != nil {
			http.Error(w, "перечитать не удалось: "+err.Error(), http.StatusInternalServerError)
			log.Printf("admin: перечитать реестр не удалось: %v", err)
			return
		}
		killed := 0
		for _, id := range reg.revokedIDs() {
			killed += installs.killInstall(id)
		}
		log.Printf("admin: реестр перечитан (%d записей), оборвано сессий у отозванных: %d", n, killed)
		fmt.Fprintf(w, "перечитано записей: %d, оборвано сессий: %d\n", n, killed)
	})

	return mux
}

// startAdmin поднимает служебный слушатель. Возвращает функцию остановки.
func startAdmin(addr string) func() {
	if addr == "" {
		return func() {}
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		log.Fatalf("--admin-addr: не разобрать адрес %q: %v", addr, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		log.Fatalf("--admin-addr должен быть петлевым (127.0.0.1 или ::1), а не %q: "+
			"иначе отзыв чужих установок окажется доступен из интернета", host)
	}
	if *adminToken == "" {
		log.Printf("ВНИМАНИЕ: служебный интерфейс без --admin-token — доступен любому процессу на этой машине")
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           newAdminMux(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("служебный интерфейс: %v", err)
		}
	}()
	log.Printf("служебный интерфейс на %s", addr)
	return func() { _ = srv.Close() }
}
