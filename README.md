# z2k v2.0 — Zapret2 для Keenetic

**Telegram-группа: [@zapret2keenetic](https://t.me/zapret2keenetic)** — вопросы, помощь с настройкой, обсуждение

Поддержать проект:

- TON: `UQA6Y6Mf1Qge2dVSl3_vSqb29SKrhI8VgJtoRBjgp08oB8QY`
- USDT (ERC20): `0xA1D6d7d339f05C1560ecAF0c5CB8c4dc80Dc46A9`

## Огромная благодарность спонсорам проекта

- **SupWgeneral**
- **Alexey**

**Важно:** после установки применяются autocircular стратегии. Им нужно время и несколько попыток, чтобы подстроиться под сетевую среду. Если сайт не открывается сразу — дайте странице несколько раз перезагрузиться. Параметры перебираются автоматически, после чего соединение обычно стабилизируется.

> Данный проект предназначен для исследования сетевых протоколов и изучения работы систем анализа трафика. Используется исключительно в учебных целях.

---

## Что это

z2k — модульный установщик zapret2 для роутеров Keenetic с Entware.

Цель проекта: упростить установку zapret2 на Keenetic и предоставить набор сетевых стратегий с автоподбором (autocircular), персистентной памятью, телеметрией и полной поддержкой IPv4/IPv6.

---

## Особенности

### Сетевые стратегии

- Установка zapret2 (openwrt-embedded релиз) без компиляции, с проверкой работоспособности `nfqws2`
- Три TCP autocircular профиля с разными стратегиями:
  - **RKN** — список ресурсов (TCP/TLS + HTTP) — 48 стратегий
  - **YouTube TCP** — youtube.com и связанные домены — 22 стратегии
  - **YouTube GV** — googlevideo CDN (стриминг) — 22 стратегии
- QUIC autocircular профили: YouTube QUIC (UDP/443) и Discord voice — по 12 стратегий с z2k morph
- Discord профили:
  - TCP: hostlist Discord включён в RKN-профиль
  - UDP voice/video: `circular_locked` (стратегия закрепляется per-domain)
- ECH (Encrypted Client Hello) detection — автоматический пропуск desync когда SNI зашифрован
- Hostlist режим: стратегии применяются только к доменам из списков
- Whitelist: домены-исключения (госуслуги, Steam, VK, Яндекс и др.) не обрабатываются

### Сеть и прокси

- **Telegram** — прозрачная работа для всех устройств в сети, без настройки на клиентах
- **IPv6** — полная поддержка: dual-stack DNS, IPv6 SO_ORIGINAL_DST, Telegram DC IPv6 CIDR
- **Игровой режим** — два профиля для UDP-игр на портах 1024-65535:
  - `flowseal` — catchall autocircular поверх диапазона
  - `legacy` — 13-стратный rotator с режимами `safe / hybrid / aggressive` под AWS-игры (Darktide, Outlast и др.)

### Инструменты и мониторинг

- **Веб-панель** — мониторинг через браузер (CGI): статус сервиса, стратегии, логи
- **Health check** — автоматическая проверка доступности сервисов (YouTube, Discord, RKN)
- **Config validator** — валидация конфигурации перед применением (порты, hostlist-файлы, blob-файлы, lua-desync)
- **Rollback** — откат конфигурации к предыдущему snapshot с авто-таймером
- **Auto updater** — автоматическое обновление списков доменов по cron
- **Телеметрия** — UCB1-scoring стратегий, латентность, cooldown (опционально)

### Качество кода

- **0 shellcheck warnings** — все shell-скрипты чистые
- **0 go vet issues** — Go код без замечаний
- **CI/CD** — GitHub Actions: shellcheck, go build/vet, luacheck, кросс-компиляция 9 архитектур

---

## Установка

### 1) Требования к прошивке Keenetic (обязательно)

Перед установкой zapret2 в веб-интерфейсе Keenetic нужно установить компоненты:

1. "Протокол IPv6"
2. "Модули ядра подсистемы Netfilter" (появляется только после выбора компонента "Протокол IPv6")

### 2) Подготовка USB и установка Entware (обязательно)

Подготовьте USB-накопитель и установите Entware по официальной инструкции Keenetic:
https://help.keenetic.com/hc/ru/articles/360021214160

После установки Entware выполните обновление индекса пакетов и установите зависимости:

```bash
opkg update
opkg install coreutils-sort curl grep gzip ipset iptables kmod_ndms xtables-addons_legacy libnghttp2
```

### 3) Установка z2k

```bash
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh | sh
```

Если GitHub заблокирован провайдером — установка через зеркало:

```bash
# jsdelivr
curl -fsSL https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k.sh | sh

# gh-proxy
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh | sh
```

---

## Меню

После установки доступно интерактивное меню:

```bash
z2k menu
```

| Пункт | Описание |
|---|---|
| **[1]** | Установить/переустановить zapret2 |
| **[2]** | Управление сервисом (старт/стоп/рестарт/статус) |
| **[3]** | Обновить списки доменов |
| **[4]** | Резервная копия/восстановление |
| **[5]** | Удалить zapret2 |
| **[U]** | Проверить обновления z2k |
| **[W]** | Whitelist — управление списком исключений |
| **[R]** | RST-фильтр — фильтрация аномальных TCP RST |
| **[F]** | Silent fallback для РКН (осторожно — возможны поломки) |
| **[G]** | Игровой режим (safe/hybrid/aggressive) |
| **[T]** | Telegram прокси |
| **[S]** | Скрипты custom.d |
| **[P]** | Веб-панель |
| **[D]** | Диагностика (сводка для траблшутинга) |
| **[X]** | Active probe (подбор стратегии под домен) |
| **[C]** | Classify — определить тип DPI-блока (5–30 с) |
| **[I]** | Убрать статические IP Instagram (обход DNS-отравления) |

---

## Командная строка

После установки появляется короткая команда `z2k` в `/opt/bin/` — можно вызывать из любого места:

```bash
z2k <команда>
```

| Команда | Описание |
|---|---|
| `menu`, `m` | Открыть интерактивное меню |
| `install`, `i` | Установить zapret2 |
| `uninstall` | Удалить zapret2 (снимает и TG tunnel) |
| `status`, `s` | Показать статус системы |
| `check`, `info` | Показать какие списки обрабатываются |
| `diag`, `d` | Одностраничная сводка для траблшутинга |
| `probe`, `p <host>` | Подбор стратегии под конкретный домен |
| `update`, `u` | Обновить z2k до последней версии |
| `rollback` | Откатить конфигурацию к snapshot |
| `snapshot` | Создать snapshot конфигурации |
| `healthcheck`, `hc` | Проверить доступность сервисов |
| `validate` | Валидация текущей конфигурации |
| `cleanup` | Очистить старые бэкапы (оставить 5) |
| `version`, `v` | Показать версию |
| `help`, `h` | Показать справку |

---

## Как работает autocircular

Каждый TCP/QUIC профиль содержит N стратегий с номерами `strategy=1..N`. Модуль `circular` в nfqws2 отслеживает успех/неудачу per-domain и переключается на следующую стратегию при неудаче. Успешная стратегия закрепляется.

### Детекция неудач

- **Стандартный детектор** — TCP ретрансмиссии и аномальные RST
- **UDP детектор** — соотношение отправленных/полученных пакетов (4+ out, ≤1 in = неудача)
- **TLS alert детектор** (`z2k_tls_alert_fatal`) — анализирует TLS alert + HTTP redirect
- **Mid-stream stall детектор** (`z2k_mid_stream_stall`) — ловит «тихие» разрывы посередине потока, когда DPI режет соединение без RST/alert
- **3-state HTTP classifier** — отличает positive/neutral/hard_fail на HTTP-ответе (с `inseq=18000` и `no_http_redirect`), чтобы не зачитывать редирект на блок-страницу как успех
- **IP block detector** (`--ipblock-detect=on` в nfqws2) — если 3+ ClientHello к одному IP не получают ответа, шлёт client RST чтобы приложение быстро переключилось на другой IP

### Персистентность

Найденные рабочие стратегии сохраняются в `state.tsv` и переживают перезапуск сервиса. Файл защищён от конкурентной записи через lock-механизм с atomic rename. Режим `z2k probe` во время перебора использует transient live-override в `/tmp`, а в `state.tsv` пишет только выбранного победителя при `--apply`.

### Телеметрия (опционально)

При включении policy-режима стратегии оцениваются через UCB1 алгоритм (multi-armed bandit) с учётом:
- Success rate per strategy per domain
- Латентность (EMA)
- Cooldown при неудачах

---

## Веб-панель мониторинга

Встроенная веб-панель для просмотра состояния через браузер.

Установка через меню z2k:

1. Запустить меню: `sh /opt/zapret2/z2k.sh menu` (или `z2k menu`)
2. Выбрать `[P]` → `[1]` (Установить/Переустановить)

После установки панель доступна в локальной сети по адресу `http://ROUTER_IP:8088/` (порт 8088, без авторизации).

Панель показывает:
- Статус сервиса (PID, uptime)
- Текущие стратегии по категориям
- Состояние autocircular (домены, стратегии)
- Логи healthcheck и debug
- Системную информацию (память, диск, нагрузка)
- Статус rollback-snapshot

---

## Telegram

Telegram работает для всех устройств в сети автоматически, без настройки на клиентах. Включается при установке или через меню `[T]`.

---

## Пользовательские стратегии

Для добавления собственных стратегий без модификации основного кода создайте файлы в директории:

```
/opt/zapret2/extra_strats/custom_strategies.d/
```

Формат файла: `CATEGORY_PROTOCOL.conf` (например `MYSITE_TCP.conf`), содержимое — параметры nfqws2.

---

## Управление сервисом

```bash
/opt/etc/init.d/S99zapret2 start
/opt/etc/init.d/S99zapret2 stop
/opt/etc/init.d/S99zapret2 restart
/opt/etc/init.d/S99zapret2 status
```

---

## Полная зачистка (z2k_cleanup)

Если zapret или zapret2 были удалены некорректно, остались зависшие процессы или мусорные правила — используйте скрипт полной зачистки:

```bash
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh | sh
```

Через зеркала (если GitHub заблокирован):

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k_cleanup.sh | sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh | sh
```

**ВНИМАНИЕ:** Скрипт удаляет ВСЁ связанное с zapret и zapret2:
- Останавливает все процессы `nfqws` и `nfqws2`
- Удаляет init-скрипты, netfilter хуки, iptables цепочки
- **Полностью удаляет директории `/opt/zapret` и `/opt/zapret2`** (включая конфиги, списки, стратегии)
- Очищает ipset и временные файлы

После зачистки можно выполнить чистую установку z2k.

---

## Поддерживаемые архитектуры

Архитектура определяется автоматически. Поддерживаются все платформы из zapret2 openwrt-embedded:

| Архитектура | Роутеры |
|---|---|
| `arm64` / `aarch64` | Keenetic Hero, Ultra, Giga, Hopper и другие на ARM Cortex-A |
| `arm` | Более старые модели на ARM |
| `mipsel` | Keenetic на MT7621 (Extra, Start, Air и др.) |
| `mips` | Older MIPS big-endian |
| `mips64` | MIPS64 |
| `lexra` | Realtek Lexra |
| `x86` / `x86_64` | x86-роутеры и виртуальные машины |
| `riscv64` | RISC-V |
| `ppc` | PowerPC |

---

## Структура проекта

```
z2k/
├── z2k.sh                      # Bootstrap / main installer
├── z2k_cleanup.sh              # Complete uninstall
├── strats_new2.txt             # TCP strategy database (RKN 48 / YT 22 / GV 22)
├── quic_strats.ini             # UDP/QUIC strategy database (yt_quic + discord_voice)
├── lib/                        # Core modules (загружаются z2k.sh)
│   ├── utils.sh                # Utilities, safe_config_read, z2k_fetch с 5-layer fallback
│   ├── system_init.sh          # System detection
│   ├── install.sh              # 16-step install + rollback
│   ├── strategies.sh           # Strategy parsing & management
│   ├── config.sh               # Configuration management
│   ├── config_official.sh      # nfqws2 config generation
│   ├── webpanel.sh             # CGI веб-панель installer
│   ├── menu.sh                 # Interactive menu (16 опций)
│   └── auto_update.sh          # Self-update z2k через UPDATES.json
├── files/
│   ├── S99zapret2.new          # Init script
│   ├── 000-zapret2.sh          # ndmc hook
│   ├── init.d/                 # Дополнительные init-скрипты (TG watchdog и др.)
│   ├── ndm/                    # Keenetic ndmc-интеграция
│   ├── fake/                   # Binary protocol blobs (24 файла)
│   ├── lua/
│   │   ├── z2k-autocircular.lua    # Persistent strategy memory + telemetry
│   │   └── z2k-modern-core.lua     # IP frag, QUIC morph, TLS shuffle, ECH, mid-stream stall
│   ├── lists/                  # Domain & IP lists (RKN, YouTube, Discord, AWS, Roblox, TG, flowseal)
│   ├── z2k-healthcheck.sh      # Service availability monitoring
│   ├── z2k-config-validator.sh # Config validation
│   ├── z2k-update-lists.sh     # Auto domain list updater
│   ├── z2k-auto-update.sh      # Self-update cron entry
│   ├── z2k-geosite.sh          # Geosite ru-blocked import
│   ├── z2k-classify-drift.sh   # DPI-block type classifier (drift)
│   ├── z2k-classify-inject.sh  # DPI-block type classifier (inject)
│   ├── z2k-probe.sh            # Active probe per-host
│   ├── z2k-diag.sh             # Single-page troubleshooting summary
│   ├── z2k-blocked-monitor.sh  # Watch nfqws2 logs for blocked sessions
│   ├── z2k-tg-watchdog.sh      # Telegram tunnel health watchdog
│   ├── z2k-fix-tg-iptables.sh  # TG NAT/iptables hotfix
│   └── z2k-fix-tg-watchdog.sh  # TG watchdog hotfix
├── cf-worker/                  # Cloudflare Worker relay
│   ├── worker.js               # Telegram relay
│   └── wrangler.toml           # Deployment config
├── mtproxy-client/             # Telegram tunnel (Go)
│   ├── main.go                 # Entry point
│   ├── tunnel.go               # Tunnel client
│   └── listener.go             # SO_ORIGINAL_DST (IPv4 + IPv6)
├── tests/                      # Test framework (12 .sh + .lua fixtures)
│   ├── run_all.sh
│   ├── test_utils.sh, test_strategies.sh, test_config_official.sh, test_validator.sh
│   ├── test_http_classifier.{sh,lua}, test_http_mid_stream_stall.{sh,lua}
│   ├── test_mid_stream_stall.{sh,lua}, test_probe_override.{sh,lua}
│   ├── test_init_rst_filter.sh, test_inject_z2k_range_rand.sh
│   ├── test_install_completeness.sh
│   └── test_rotate_rkn_tcp_ts_slots.sh
└── .github/workflows/
    ├── ci.yml                  # shellcheck + go + luacheck + cross-arch build
    ├── build-classify.yml      # Build classify-* helpers
    └── jsdelivr-purge.yml      # Сбросить jsdelivr CDN после релиза
```

---

## Примечания

- Если вы используете IPv6 в сети, убедитесь что он включён в прошивке (см. требования выше).
- Автообновление списков доменов — через cron (`/opt/zapret2/z2k-update-lists.sh`).
- Если конкретный сайт не открывается — подбери под него стратегию через `z2k probe <host>` (например `z2k probe cloudflare.com`).
- `RST_FILTER` по умолчанию выключен для совместимости с Cloudflare; если у провайдера подтверждены fake-RST инжекты ТСПУ, добавь `RST_FILTER=1` в `/opt/zapret2/config` и перезапусти сервис.
- Для траблшутинга пришли вывод `z2k diag` — это одностраничная сводка о состоянии всех компонентов.
- Валидация конфигурации: `z2k validate`. Откат: `z2k rollback`.

---

## Лицензия

MIT
