// Функциональные тесты проверяльщика подписи.
//
// ЗАЧЕМ ОНИ ВООБЩЕ. До 2026-08-09 этот модуль не исполнялся ни одним тестом и
// не собирался ни одной джобой CI. При этом его sha256 запинен в z2k.sh, а
// роутер с защёлкнутым храповиком без работающего проверяльщика отвергает
// манифест — то есть его поломка означает «обновления встали одновременно у
// всего парка». Единственный компонент с такой ценой отказа был единственным
// без автоматики.
//
// Проверяется КОНТРАКТ КОДОВ ВОЗВРАТА, а не внутренности. На него завязан
// au_manifest_verify в lib/auto_update.sh, который обязан различать «подпись
// не сходится» (1) и «проверить нечем» (2): первое — отказ публикации, второе —
// молчаливый пропуск до защёлкивания храповика. Схлопни их — и роутер начнёт
// принимать неподписанное или, наоборот, встанет навсегда.
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// buildOnce собирает проверяльщик один раз на весь прогон: тестируем поведение
// процесса, а не функций, потому что контракт — это именно коды возврата.
func buildOnce(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "z2k-verify")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("сборка не удалась: %v\n%s", err, out)
	}
	return bin
}

// writePubPEM кладёт ключ в том же виде, в каком его пишет `openssl pkey -pubout`
// — SubjectPublicKeyInfo. Любой другой формат сюда не доедет с роутера.
func writePubPEM(t *testing.T, dir string, pub ed25519.PublicKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	p := filepath.Join(dir, "pub.pem")
	if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p
}

func exitCode(t *testing.T, bin string, args ...string) int {
	t.Helper()
	err := exec.Command(bin, args...).Run()
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if ok := asExitError(err, &ee); ok {
		return ee.ExitCode()
	}
	t.Fatalf("запуск не состоялся: %v", err)
	return -1
}

func asExitError(err error, target **exec.ExitError) bool {
	if ee, ok := err.(*exec.ExitError); ok {
		*target = ee
		return true
	}
	return false
}

func TestExitCodeContract(t *testing.T) {
	bin := buildOnce(t)
	dir := t.TempDir()

	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("генерация ключа: %v", err)
	}
	pubPath := writePubPEM(t, dir, pub)

	msgPath := filepath.Join(dir, "UPDATES.json")
	msg := []byte(`{"schema":1,"current":"p-1.0"}`)
	if err := os.WriteFile(msgPath, msg, 0o644); err != nil {
		t.Fatal(err)
	}

	sigPath := filepath.Join(dir, "UPDATES.json.sig")
	if err := os.WriteFile(sigPath, ed25519.Sign(priv, msg), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := exitCode(t, bin, pubPath, sigPath, msgPath); got != 0 {
		t.Errorf("валидная подпись: код %d, ожидался 0", got)
	}

	// Манифест правлен после подписи — ровно то, что случается, когда релиз
	// дособирают руками уже после подписания.
	tampered := filepath.Join(dir, "tampered.json")
	if err := os.WriteFile(tampered, []byte(`{"schema":1,"current":"p-9.9"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := exitCode(t, bin, pubPath, sigPath, tampered); got != 1 {
		t.Errorf("подменённый файл: код %d, ожидался 1", got)
	}

	// Подпись чужим ключом. Отличать её от «нечем проверить» обязательно:
	// первое означает отказ, второе — пропуск.
	otherPub, otherPriv, _ := ed25519.GenerateKey(nil)
	_ = otherPub
	foreign := filepath.Join(dir, "foreign.sig")
	if err := os.WriteFile(foreign, ed25519.Sign(otherPriv, msg), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := exitCode(t, bin, pubPath, foreign, msgPath); got != 1 {
		t.Errorf("подпись чужим ключом: код %d, ожидался 1", got)
	}

	// Обрезанная подпись. Без явной проверки длины ed25519.Verify паникует, а
	// паника снаружи неотличима от чего угодно — вызывающий примет её за отказ
	// или за успех в зависимости от того, как читает код.
	short := filepath.Join(dir, "short.sig")
	if err := os.WriteFile(short, []byte("слишком коротко"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := exitCode(t, bin, pubPath, short, msgPath); got != 1 {
		t.Errorf("обрезанная подпись: код %d, ожидался 1 (паника недопустима)", got)
	}

	// Неверный вызов — 2, и это НЕ то же самое, что неверная подпись.
	if got := exitCode(t, bin, pubPath, sigPath); got != 2 {
		t.Errorf("неверное число аргументов: код %d, ожидался 2", got)
	}
	if got := exitCode(t, bin); got != 2 {
		t.Errorf("вызов без аргументов: код %d, ожидался 2", got)
	}
}

// В проверяльщике не должно быть ничего изменчивого: ни ключа, ни версии.
// Иначе ротация ключа = пересборка девяти арок и десятки мегабайт в историю
// git, который бинарники не дельтит. Ключ приходит аргументом — здесь это
// закрепляется исполнением: чужой ключ на входе меняет вердикт.
func TestKeyComesFromArgument(t *testing.T) {
	bin := buildOnce(t)
	dir := t.TempDir()

	pubA, privA, _ := ed25519.GenerateKey(nil)
	pubB, _, _ := ed25519.GenerateKey(nil)

	msgPath := filepath.Join(dir, "m")
	msg := []byte("payload")
	if err := os.WriteFile(msgPath, msg, 0o644); err != nil {
		t.Fatal(err)
	}
	sigPath := filepath.Join(dir, "m.sig")
	if err := os.WriteFile(sigPath, ed25519.Sign(privA, msg), 0o644); err != nil {
		t.Fatal(err)
	}

	dirA, dirB := t.TempDir(), t.TempDir()
	if got := exitCode(t, bin, writePubPEM(t, dirA, pubA), sigPath, msgPath); got != 0 {
		t.Errorf("свой ключ: код %d, ожидался 0", got)
	}
	if got := exitCode(t, bin, writePubPEM(t, dirB, pubB), sigPath, msgPath); got != 1 {
		t.Errorf("чужой ключ: код %d, ожидался 1", got)
	}
}

// Мусор вместо ключа — это «проверить нечем» по сути, но снаружи важно одно:
// процесс не должен упасть паникой и не должен сказать «подпись верна».
func TestGarbageKeyIsNotSuccess(t *testing.T) {
	bin := buildOnce(t)
	dir := t.TempDir()

	msgPath := filepath.Join(dir, "m")
	if err := os.WriteFile(msgPath, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sigPath := filepath.Join(dir, "m.sig")
	if err := os.WriteFile(sigPath, make([]byte, ed25519.SignatureSize), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, body := range []string{
		"не PEM вовсе",
		"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
		"-----BEGIN PUBLIC KEY-----\nбред\n-----END PUBLIC KEY-----\n",
	} {
		p := filepath.Join(t.TempDir(), "bad.pem")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := exitCode(t, bin, p, sigPath, msgPath); got == 0 {
			t.Errorf("мусорный ключ принят как валидная подпись (код 0): %.30q", body)
		}
	}
}
