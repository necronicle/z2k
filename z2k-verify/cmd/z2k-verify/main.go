// z2k-verify — проверка Ed25519-подписи файла. Больше он не умеет ничего.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ БИНАРНИК, а не openssl. Проверять подпись манифеста нечем,
// кроме того, что уже стоит на роутере, — а стоит там `openssl-util` из
// opkg-фида, который на Entware ходит по ОТКРЫТОМУ HTTP (busybox wget собран
// без SSL, https-зеркало отдаёт 301 и мертво). Получается петля: корень доверия
// приезжает по каналу, который сам ничем не защищён. Плюс `pkeyutl -rawin`
// появился только в OpenSSL 3.0, и на 1.1.1 проверки нет вовсе.
//
// Этот бинарник петлю рвёт, а не переносит: его sha256 вшит в z2k.sh, то есть
// он адресуется содержимым. Транспорт для него перестаёт быть доверенным —
// подменённый на любом зеркале файл не совпадёт с ожидаемым дайджестом.
//
// ЧЕГО ЗДЕСЬ НАМЕРЕННО НЕТ.
//
// Ни публичного ключа, ни версии, ни любого другого изменчивого значения. Всё
// приходит аргументами. Причина практическая: git не дельтит бинарники, а мы
// собираем девять арок — вшей мы сюда ключ, ротация ключа стоила бы полной
// пересборки и десятков мегабайт в историю при каждой смене. С таким контрактом
// пересборка нужна только при бампе тулчейна, то есть примерно никогда.
//
// КОНТРАКТ — КОД ВОЗВРАТА, не текст на stdout. Парсить вывод чужого процесса в
// shell значит однажды принять "verification failure" за успех, потому что
// grep нашёл в строке нужное слово.
//
//	0 — подпись верна
//	1 — подпись НЕ верна (или файл/подпись/ключ не читаются)
//	2 — неверный вызов
//
// На stdout не печатается ничего. Диагностика — на stderr.
//
// GODEBUG прибит по той же причине, что и в z2k-detect: модуль объявляет
// go 1.25.0, и без этих строк подъём директивы сменил бы умолчания рантайма.
// Здесь нет сети и TLS, поэтому фиксируем только то, что касается исполнения.
//
//go:debug asynctimerchan=1
//go:debug containermaxprocs=0
//go:debug updatemaxprocs=0
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
)

const usage = `z2k-verify <pubkey.pem> <signature> <file>

Проверяет Ed25519-подпись файла. Ничего не печатает при успехе.
Код возврата: 0 — верна, 1 — не верна, 2 — неверный вызов.`

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	pubPath, sigPath, filePath := os.Args[1], os.Args[2], os.Args[3]

	pub, err := loadPubkey(pubPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "z2k-verify: ключ: %v\n", err)
		os.Exit(1)
	}

	sig, err := os.ReadFile(sigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "z2k-verify: подпись: %v\n", err)
		os.Exit(1)
	}
	// Длину проверяем явно: ed25519.Verify на кривой длине паникует, а паника
	// из проверяльщика — это не «подпись плохая», это упавший процесс, который
	// вызывающий может принять за что угодно.
	if len(sig) != ed25519.SignatureSize {
		fmt.Fprintf(os.Stderr, "z2k-verify: длина подписи %d, ожидалось %d\n",
			len(sig), ed25519.SignatureSize)
		os.Exit(1)
	}

	msg, err := os.ReadFile(filePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "z2k-verify: файл: %v\n", err)
		os.Exit(1)
	}

	if !ed25519.Verify(pub, msg, sig) {
		fmt.Fprintln(os.Stderr, "z2k-verify: подпись не сходится")
		os.Exit(1)
	}
	os.Exit(0)
}

// loadPubkey читает Ed25519-ключ из PEM в том виде, в каком его пишет
// `openssl pkey -pubout` — то есть SubjectPublicKeyInfo.
func loadPubkey(path string) (ed25519.PublicKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("не PEM")
	}
	if block.Type != "PUBLIC KEY" {
		return nil, fmt.Errorf("PEM-блок %q, ожидался PUBLIC KEY", block.Type)
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := parsed.(ed25519.PublicKey)
	if !ok {
		// Ключ другого алгоритма — это не «подпись не сошлась», это неверная
		// настройка, но снаружи разница не важна: проверить мы всё равно не можем.
		return nil, fmt.Errorf("ключ не Ed25519 (%T)", parsed)
	}
	return pub, nil
}
