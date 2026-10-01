# z2k VPS relay — build & deploy

The relay (`/usr/local/bin/z2k-vps-relay`) runs on the Aeza VPS behind the
nginx `:443` SNI stream router → caddy (TLS + `/ws`) → relay `127.0.0.1:8080`.
It is **deployed by hand on the VPS** and is deliberately decoupled from the
router auto-update fleet (only the *client* binaries in `mtproxy-client/builds/`
ship via `UPDATES.json`). This dir exists so that decoupled deploy is
reproducible and documented, not tribal knowledge.

## Files

- `build.sh` — reproducible static `linux/amd64` build → `vps-relay/z2k-vps-relay`.
- `z2k-relay.service` — reference unit (secrets are placeholders; the live unit
  on the VPS holds the real values). Source-of-truth for the invocation flags.
- `20-gomemlimit.conf` — systemd drop-in that sets `GOMEMLIMIT=1500MiB`
  (non-invasive; does not touch the main unit or its secrets).

## Deploy (off-peak — restarting drops all live tunnels; they reconnect)

```sh
# 1. build (from repo root)
sh vps-relay/deploy/build.sh

# 2. copy the binary up
scp vps-relay/z2k-vps-relay root@<vps>:/usr/local/bin/z2k-vps-relay.new

# 3. on the VPS: apply the GOMEMLIMIT drop-in (one-time)
mkdir -p /etc/systemd/system/z2k-relay.service.d
scp vps-relay/deploy/20-gomemlimit.conf \
    root@<vps>:/etc/systemd/system/z2k-relay.service.d/20-gomemlimit.conf

# 4. on the VPS: swap binary + restart (atomic-ish; off-peak)
mv /usr/local/bin/z2k-vps-relay.new /usr/local/bin/z2k-vps-relay
chmod +x /usr/local/bin/z2k-vps-relay
systemctl daemon-reload
systemctl restart z2k-relay
```

## Verify after deploy

```sh
# RSS should fall from ~0.9 GB toward ~0.15-0.3 GB at ~1600 tunnels
grep VmRSS /proc/$(pgrep -f z2k-vps-relay)/status
free -m                       # swap usage should drop
# dialing to Telegram must stay healthy across the restart
journalctl -u z2k-relay -n 20 | grep 'dial summary'   # fail=0 throttle=0 p95~45ms
```

## Rollback

Keep the previous `/usr/local/bin/z2k-vps-relay` (e.g. `.bak`); restore it and
`systemctl restart z2k-relay`. The `20-gomemlimit.conf` drop-in is independent
and safe to leave in place.

---

# Учёт по установкам и отзыв

Кого мы ловим: не того, кто не заплатил, а того, кто встроил релей в свой
продукт и раздаёт туннель дальше. У такого одна установка обслуживает много
людей, то есть с ОДНОГО `install_id` идут подключения с множества разных
адресов. Домашний роутер — один адрес, изредка два.

Замер по живому логу за три часа (636 установок): максимум разных адресов у
одной установки — **2**, в потолок одновременных сессий (64) не упёрся никто ни
разу. Нормальное поведение сидит далеко от любых порогов.

## Служебный интерфейс

Отдельный слушатель `127.0.0.1:9098`, **не** основной `:8080`: caddy проксирует
на основной всё подряд (`reverse_proxy localhost:8080`, без разбора путей), и
`/admin/...` на нём оказался бы доступен из интернета. Нептлевой `--admin-addr`
роняет процесс на старте намеренно.

Токен лежит в `ExecStart` живого юнита (там же, где остальные секреты).

```sh
A() { curl -s -H "X-Z2K-Admin: $(sed -n 's/.*--admin-token=\([^ ]*\).*/\1/p' \
      /etc/systemd/system/z2k-relay.service.d/10-require-per-install.conf)" "$@"; }

A http://127.0.0.1:9098/admin/installs            # сводка (сортировка по числу адресов)
A -X POST 'http://127.0.0.1:9098/admin/revoke?id=<install_id>'
A -X POST 'http://127.0.0.1:9098/admin/unrevoke?id=<install_id>'
A -X POST  http://127.0.0.1:9098/admin/reload     # после правки registry.json руками
```

Поля сводки: `IPs` — разных адресов за сутки (`Capped` = упёрлись в предел
слежения 256), `Live`/`Peak` — сессий сейчас и пик за сутки, `Sessions` —
открыто за сутки, `Rejected` — отбито потолком, `Bytes` — объём за сутки,
`FirstSeen` — когда установка впервые попала в учёт после старта релея.

Раз в 10 минут та же сводка уходит в журнал (`install summary:`), поэтому
история видна и задним числом, через `journalctl`.

## Что делает отзыв

Проверено сквозняком на отдельной тестовой установке:

* флаг сохраняется в `registry.json` сразу;
* **живой туннель обрывается немедленно**, а не когда отвалится сам;
* повторная регистрация тем же ключом флаг **не снимает**;
* снятие отзыва возвращает связь на следующей попытке клиента;
* правка файла руками применяется через `/admin/reload`, без перезапуска
  (перезапуск рвёт все туннели разом и ради одной записи неприемлем).

## Чего отзыв не делает

Не мешает завести новую личность. Регистрация открыта и защищена тем же
секретом, что зашит в открытый клиент, — то есть публичным. Кто удалит
`.z2k-relay-id`, получит новый `install_id` и войдёт заново.

Отзыв даёт не запрет, а **рычаг**: опознать, посчитать и отрезать конкретного.
Чем ограничивать саму выдачу — отдельный вопрос, не решённый здесь.

## Пороги

| флаг | сейчас | смысл |
|---|---|---|
| `--install-warn-ips` | 12 | только запись в лог, отсечки нет |
| `--install-max-ips` | 64 | жёсткий потолок разных адресов за сутки |
| `--per-install-max-sessions` | 64 | потолок одновременных сессий |

Жёсткие потолки намеренно не затянуты: данных на сутки ещё нет, а ошибка здесь
отрезает своего же человека. Пик одновременных сессий (`Peak`) и число адресов
теперь считаются — по ним и затягивать, когда наберётся сутки-двое. Первые
замеры после включения: пик 4 при потолке 64.

## Назначение узла и пределы соединений

`--routes-file=/var/lib/z2k-relay/routes.json` включает необязательную карту
`install_id → {"url":"wss://relay.example/ws","max_connections":4096}`.
Файл содержит административную политику и хранится вне репозитория с правами
600 владельца службы. Перед включением флага создайте файл (`{}` для пустой
карты). Изменения применяются через `/admin/reload`; ошибочная карта оставляет
предыдущую в памяти. Для удаления всех назначений запишите `{}` и перечитайте.

Назначение выдаётся только после проверки подписи текущего nonce и только
клиенту, объявившему capability 1 в HELLO. INFO kind 5 содержит предел в arg
и WSS URL в text. Отозванная установка с назначением получает адрес, но доступ
к данным на исходном узле остаётся закрыт. Ключ нужно заранее внести в реестр
целевого узла. Повторные перенаправления и перенос регистрации общего секрета
на целевой адрес клиент не допускает.

Клиент сохраняет назначение внутри `.z2k-relay-id`, проверяет его при подключении
и раз в 10 минут. Сетевой отказ исходного узла допускает сохранённый адрес;
явный отказ авторизации удаляет назначение. Обновление и переустановка сохраняют
его вместе с ключом. Не удаляйте файл личности при смене адреса.

`--registration-closed` запрещает выдачу новых идентификаторов; ранее внесённые
ключи продолжают проходить персональную авторизацию. `--max-streams-total`
ограничивает сумму ожидающих и открытых потоков во всех сессиях процесса,
независимо от `--max-streams-per-session`. Ноль оставляет прежнее поведение.
Во время blue/green оба процесса имеют собственный предел: ограничения памяти
и ёмкости хоста должны учитывать временное сосуществование.

Назначение допускает до 8192 соединений; явный клиентский `--max-conns` и доступные
файловые дескрипторы дополнительно снижают этот предел. Без назначения остаётся
прежнее значение 1024. Повышение числа соединений не повышает пропускную
способность канала: память, очереди и фактическую скорость проверяют отдельно.
