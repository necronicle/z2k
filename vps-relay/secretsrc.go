package main

import (
	"fmt"
	"os"
	"strings"
)

// resolveSecretValue разбирает значение флага-секрета.
//
// ЗАЧЕМ. Секреты передавались релею прямо в командной строке, а её видит любой
// процесс на машине через /proc/<pid>/cmdline. Вынести их в EnvironmentFile
// systemd недостаточно: systemd подставляет ${VAR} ДО запуска, и в argv уезжает
// уже настоящее значение — проверено на живом узле 31.08.2026.
//
// Поэтому подстановку делает сам процесс. Поддерживаются три формы:
//
//	<значение>   — как раньше, литерал (совместимость не ломается);
//	env:ИМЯ      — взять из переменной окружения ИМЯ;
//	@/путь       — прочитать из файла (первая строка, пробелы обрезаются).
//
// В argv при этом остаётся только ИМЯ переменной или путь.
func resolveSecretValue(what, raw string) (string, error) {
	switch {
	case strings.HasPrefix(raw, "env:"):
		name := strings.TrimPrefix(raw, "env:")
		if name == "" {
			return "", fmt.Errorf("%s: пустое имя переменной в env:", what)
		}
		v, ok := os.LookupEnv(name)
		if !ok {
			return "", fmt.Errorf("%s: переменная %s не задана", what, name)
		}
		if v == "" {
			return "", fmt.Errorf("%s: переменная %s пуста", what, name)
		}
		return v, nil

	case strings.HasPrefix(raw, "@"):
		path := strings.TrimPrefix(raw, "@")
		if path == "" {
			return "", fmt.Errorf("%s: пустой путь в @", what)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("%s: %w", what, err)
		}
		// Первая непустая строка: файл обычно правят руками, и перевод строки
		// в конце — норма, а не часть секрета.
		for _, line := range strings.Split(string(b), "\n") {
			if s := strings.TrimSpace(line); s != "" {
				return s, nil
			}
		}
		return "", fmt.Errorf("%s: файл %s пуст", what, path)

	default:
		return raw, nil
	}
}

// resolveAllSecrets применяет разбор ко всем секретам сразу. Вызывается один
// раз после flag.Parse: дальше по коду секреты используются как обычные строки.
func resolveAllSecrets() error {
	for _, s := range []struct {
		name string
		p    *string
	}{
		{"--secret", secret},
		{"--secret-prev", secretPrev},
		{"--resolve-secret", resolveSecret},
		{"--admin-token", adminToken},
	} {
		if *s.p == "" {
			continue
		}
		v, err := resolveSecretValue(s.name, *s.p)
		if err != nil {
			return err
		}
		*s.p = v
	}
	return nil
}
