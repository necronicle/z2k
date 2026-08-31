package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Секрет не должен попадать в командную строку: её видит любой процесс через
// /proc/<pid>/cmdline. Вынос в EnvironmentFile systemd этого НЕ решает —
// systemd подставляет ${VAR} до запуска, и в argv уезжает настоящее значение
// (проверено на живом узле 31.08.2026). Поэтому подстановку делает процесс.
func TestResolveSecretValue(t *testing.T) {
	t.Run("литерал остаётся литералом", func(t *testing.T) {
		got, err := resolveSecretValue("--secret", "abc123")
		if err != nil || got != "abc123" {
			t.Fatalf("хотел abc123, получил %q, ошибка %v", got, err)
		}
	})

	t.Run("env: берёт из окружения", func(t *testing.T) {
		t.Setenv("Z2K_TEST_SECRET", "изфайлаокружения")
		got, err := resolveSecretValue("--secret", "env:Z2K_TEST_SECRET")
		if err != nil || got != "изфайлаокружения" {
			t.Fatalf("хотел значение из окружения, получил %q, ошибка %v", got, err)
		}
	})

	t.Run("env: незаданная переменная — ошибка, а не пустой секрет", func(t *testing.T) {
		// Молча стартовать с пустым секретом хуже, чем не стартовать:
		// пустой --admin-token отключает проверку служебного интерфейса.
		if _, err := resolveSecretValue("--admin-token", "env:Z2K_NET_TAKOJ_PEREMENNOJ"); err == nil {
			t.Fatal("ожидал ошибку на незаданной переменной")
		}
	})

	t.Run("env: пустая переменная — тоже ошибка", func(t *testing.T) {
		t.Setenv("Z2K_TEST_EMPTY", "")
		if _, err := resolveSecretValue("--admin-token", "env:Z2K_TEST_EMPTY"); err == nil {
			t.Fatal("ожидал ошибку на пустой переменной")
		}
	})

	t.Run("@путь читает файл и обрезает перевод строки", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "s.txt")
		if err := os.WriteFile(p, []byte("  сизфайла  \n"), 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := resolveSecretValue("--secret", "@"+p)
		if err != nil || got != "сизфайла" {
			t.Fatalf("хотел сизфайла, получил %q, ошибка %v", got, err)
		}
	})

	t.Run("@путь: пустой файл — ошибка", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "empty.txt")
		if err := os.WriteFile(p, []byte("\n\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := resolveSecretValue("--secret", "@"+p); err == nil {
			t.Fatal("ожидал ошибку на пустом файле")
		}
	})

	t.Run("@путь: нет файла — ошибка", func(t *testing.T) {
		if _, err := resolveSecretValue("--secret", "@/net/takogo/fajla"); err == nil {
			t.Fatal("ожидал ошибку на отсутствующем файле")
		}
	})
}

// Пустой флаг не трогаем: он означает «выключено» (например, --secret-prev при
// отсутствии ротации), и превращать его в ошибку нельзя.
func TestResolveAllSecretsSkipsEmpty(t *testing.T) {
	empty := ""
	saveSecret, savePrev, saveResolve, saveAdmin := secret, secretPrev, resolveSecret, adminToken
	defer func() { secret, secretPrev, resolveSecret, adminToken = saveSecret, savePrev, saveResolve, saveAdmin }()

	lit := "литерал"
	secret, secretPrev, resolveSecret, adminToken = &lit, &empty, &empty, &empty
	if err := resolveAllSecrets(); err != nil {
		t.Fatalf("пустые флаги не должны быть ошибкой: %v", err)
	}
	if *secret != "литерал" {
		t.Fatalf("литерал испортился: %q", *secret)
	}
}
