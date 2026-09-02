# Копия golang.zx2c4.com/wireguard с правками z2k

Источник: golang.zx2c4.com/wireguard@v0.0.0-20260522210424-ecfc5a8d5446
(без tests/, main.go, main_windows.go, Makefile, format_test.go).
Подключена через `replace` в ../../go.mod.

Правки — ровно две, обе про память (замер 2026-09-02: 64 КБ на пакет при
MTU 1280 = 70–90 МБ RSS после одного файла, OOM-kill на 512 МБ):

1. device/queueconstants_default.go: `MaxSegmentSize = 2048` вместо 65535.
2. conn/bind_std.go: `supportsUDPOffload(...)` заменён на `false, false`
   для v4 и v6 — без GRO склеенные датаграммы в 2 КБ не приходят.

Обновление upstream: скопировать модуль заново, применить те же две правки,
прогнать `go test ./...` и замер памяти под скачиванием.
