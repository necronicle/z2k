# z2k v2.0 — Zapret2 для Keenetic

Поддержать проект:

- TON: `UQA6Y6Mf1Qge2dVSl3_vSqb29SKrhI8VgJtoRBjgp08oB8QY`
- USDT (ERC20): `0xA1D6d7d339f05C1560ecAF0c5CB8c4dc80Dc46A9`

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
  - **General** — список ресурсов (TCP/TLS + HTTP) — 45 стратегий
  - **YouTube TCP** — youtube.com и связанные домены — 22 стратегии
  - **YouTube GV** — googlevideo CDN (стриминг) — 22 стратегии
- QUIC autocircular профиль: YouTube QUIC (UDP/443) — 12 стратегий с z2k morph
- Discord профили:
  - TCP: hostlist Discord включён в General-профиль
  - UDP voice/video: `circular_locked` (стратегия закрепляется per-domain)
- ECH (Encrypted Client Hello) detection — автоматический пропуск desync когда SNI зашифрован
- Hostlist режим: стратегии применяются только к доменам из списков
- Whitelist: домены-исключения (госуслуги, Steam, VK, Яндекс и др.) не обрабатываются

### Сеть и прокси

- **Telegram** — прозрачный мультиплексированный туннель через Cloudflare. Все устройства в сети — автоматически, без настройки. Сетевой анализатор видит обычный HTTPS к CDN
- **IPv6** — полная поддержка: dual-stack DNS, IPv6 SO_ORIGINAL_DST, Telegram DC IPv6 CIDR
- **Roblox** — UDP-транспорт для игровых серверов (порты 1024-65535)

### Инструменты и мониторинг

- **Веб-панель** — мониторинг через браузер (busybox httpd CGI): статус сервиса, стратегии, логи, управление
- **Health check** — автоматическая проверка доступности сервисов (YouTube, Discord, Telegram, General)
- **Config validator** — валидация конфигурации перед применением (порты, hostlist-файлы, blob-файлы, lua-desync)
- **Rollback** — откат конфигурации к предыдущему snapshot с авто-таймером
- **Auto updater** — автоматическое обновление списков доменов по cron
- **Телеметрия** — UCB1-scoring стратегий, латентность, cooldown (опционально)

### Качество кода

- **0 shellcheck warnings** — все shell-скрипты чистые
- **0 go vet issues** — Go код без замечаний
- **109 автотестов** — 86 shell + 23 Go, все проходят
- **CI/CD** — GitHub Actions: shellcheck, go build/test/vet, luacheck, кросс-компиляция 6 архитектур
- **Безопасность** — нет eval/source инъекций, SHA256 верификация, rate limiting, connection deadlines

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
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/z2k.sh | sh
```

---

## Меню

После установки доступно интерактивное меню:

```bash
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/z2k.sh | sh
```

| Пункт | Описание |
|---|---|
| **[1]** | Установить/переустановить zapret2 |
| **[2]** | Управление сервисом (старт/стоп/рестарт/статус) |
| **[3]** | Обновить списки доменов |
| **[4]** | Резервная копия/восстановление |
| **[5]** | Удалить zapret2 |
| **[A]** | Режим без хостлистов (Austerus) — обработка всего TLS-трафика |
| **[W]** | Whitelist — управление списком исключений |
| **[R]** | RST-фильтр — фильтрация аномальных TCP RST |
| **[F]** | Silent fallback — ускоренная ротация при отсутствии ответа |
| **[G]** | Roblox — UDP-транспорт для игровых серверов |
| **[T]** | Telegram прокси — прозрачное проксирование через WebSocket |
| **[S]** | Скрипты custom.d |
| **[B]** | Rollback — откат конфигурации к snapshot |
| **[H]** | Health check — проверка доступности сервисов |
| **[V]** | Валидация конфигурации |

---

## Командная строка

```bash
sh z2k.sh [команда]
```

| Команда | Описание |
|---|---|
| `install` | Установить zapret2 |
| `menu` | Открыть интерактивное меню |
| `uninstall` | Удалить zapret2 |
| `status` | Показать статус системы |
| `check` | Показать какие списки обрабатываются |
| `update` | Обновить z2k до последней версии |
| `rollback` | Откатить конфигурацию к snapshot |
| `snapshot` | Создать snapshot конфигурации |
| `healthcheck` | Проверить доступность сервисов |
| `validate` | Валидация текущей конфигурации |
| `cleanup` | Очистить старые бэкапы |
| `version` | Показать версию |

---

## Как работает autocircular

Каждый TCP/QUIC профиль содержит N стратегий с номерами `strategy=1..N`. Модуль `circular` в nfqws2 отслеживает успех/неудачу per-domain и переключается на следующую стратегию при неудаче. Успешная стратегия закрепляется.

### Детекция неудач

- **Стандартный детектор** — TCP ретрансмиссии и аномальные RST
- **TLS alert детектор** (`z2k_tls_alert_fatal`) — анализирует TLS alert + HTTP redirect
- **Silent fallback** — детектор отсутствия ответа: если несколько запросов подряд без ответа, принудительно ротирует стратегию. Включается через меню [F]

### Персистентность

Найденные рабочие стратегии сохраняются в `state.tsv` и переживают перезапуск сервиса. Файл защищён от конкурентной записи через lock-механизм с atomic rename.

### Телеметрия (опционально)

При включении policy-режима стратегии оцениваются через UCB1 алгоритм (multi-armed bandit) с учётом:
- Success rate per strategy per domain
- Латентность (EMA)
- Cooldown при неудачах

---

## Веб-панель мониторинга

Встроенная веб-панель для просмотра состояния и управления через браузер:

```bash
# Установка
sh /opt/zapret2/z2k-webpanel-install.sh --port 8080

# Доступ
http://ROUTER_IP:8080/
```

Панель показывает:
- Статус сервиса (PID, uptime)
- Текущие стратегии по категориям
- Состояние autocircular (домены, стратегии)
- Логи healthcheck и debug
- Системную информацию (память, диск, нагрузка)
- Статус rollback-snapshot

Кнопки управления: restart / stop / start / очистка состояния.

---

## Telegram tunnel

Прозрачное туннелирование Telegram-трафика для всех устройств в сети. Не требует настройки на клиентах — работает автоматически.

Как это работает:

```
Устройства → TCP к Telegram DC → iptables REDIRECT → z2k-tunnel
  → мультиплексированный WS → Cloudflare Worker → TCP к Telegram DC
```

- Все TCP-соединения к Telegram мультиплексируются через **один** WebSocket
- Сетевой анализатор видит обычный HTTPS к Cloudflare CDN
- Включается автоматически при установке, или через меню `[T]`
- Протокол: кастомный бинарный мультиплексор с HMAC-SHA256 аутентификацией

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
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/z2k_cleanup.sh | sh
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
├── strats_new2.txt             # TCP strategy database (45 strategies)
├── quic_strats.ini             # UDP/QUIC strategy database
├── lib/                        # Core modules
│   ├── utils.sh                # Utilities, safe_config_read, checks
│   ├── install.sh              # 12-step install + rollback
│   ├── menu.sh                 # Interactive menu (15 options)
│   ├── strategies.sh           # Strategy parsing & management
│   ├── config.sh               # Configuration management
│   ├── config_official.sh      # nfqws2 config generation
│   └── system_init.sh          # System detection
├── files/
│   ├── S99zapret2.new          # Init script
│   ├── fake/                   # Binary protocol blobs (76 files)
│   ├── lua/
│   │   ├── z2k-autocircular.lua    # Persistent strategy memory + telemetry
│   │   └── z2k-modern-core.lua     # IP frag, QUIC morph, TLS shuffle, ECH
│   ├── lists/                  # Domain lists (General, YouTube, Discord)
│   ├── z2k-healthcheck.sh      # Service availability monitoring
│   ├── z2k-config-validator.sh # Config validation
│   ├── z2k-update-lists.sh     # Auto domain list updater
│   ├── z2k-webpanel.sh         # Web monitoring CGI
│   └── z2k-webpanel-install.sh # Web panel installer
├── cf-worker/                  # Cloudflare Worker relay
│   ├── worker.js               # Mux tunnel relay (TCP↔WS)
│   └── wrangler.toml           # Deployment config
├── mtproxy-client/             # Telegram tunnel + MTProxy (Go)
│   ├── main.go                 # Entry point + MTProxy mode
│   ├── tunnel.go               # Mux tunnel client (iptables REDIRECT → WS)
│   ├── transparent.go          # Legacy transparent WS mode
│   ├── listener.go             # SO_ORIGINAL_DST (IPv4 + IPv6)
│   ├── dcmap.go                # Telegram DC IP mapping (v4 + v6)
│   ├── relay.go                # Bidirectional MTProto relay
│   ├── secret.go               # Secret key parsing
│   └── main_test.go            # Unit tests (23 tests)
├── tests/                      # Test framework
│   ├── run_all.sh              # Test runner
│   ├── test_utils.sh           # Utils tests (23 tests)
│   ├── test_strategies.sh      # Strategy tests (21 tests)
│   ├── test_config_official.sh # Config gen tests (24 tests)
│   └── test_validator.sh       # Validator tests (18 tests)
└── .github/workflows/ci.yml   # CI: shellcheck + go + luacheck
```

---

## Примечания

- Если вы используете IPv6 в сети, убедитесь что он включён в прошивке (см. требования выше).
- Автообновление списков доменов — через cron (`/opt/zapret2/z2k-update-lists.sh`).
- Если многие сайты не открываются — попробуйте включить Silent fallback через меню [F].
- Валидация конфигурации доступна через `sh z2k.sh validate` или меню [V].
- Для отката к предыдущей конфигурации используйте `sh z2k.sh rollback` или меню [B].

---

## Лицензия

MIT
