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
  - **RKN** — список ресурсов (TCP/TLS + HTTP) — 45 стратегий
  - **YouTube TCP** — youtube.com и связанные домены — 22 стратегии
  - **YouTube GV** — googlevideo CDN (стриминг) — 22 стратегии
- QUIC autocircular профиль: YouTube QUIC (UDP/443) — 12 стратегий с z2k morph
- Discord профили:
  - TCP: hostlist Discord включён в RKN-профиль
  - UDP voice/video: `circular_locked` (стратегия закрепляется per-domain)
- ECH (Encrypted Client Hello) detection — автоматический пропуск desync когда SNI зашифрован
- Hostlist режим: стратегии применяются только к доменам из списков
- Whitelist: домены-исключения (госуслуги, Steam, VK, Яндекс и др.) не обрабатываются

### Сеть и прокси

- **Telegram** — прозрачная работа для всех устройств в сети, без настройки на клиентах
- **IPv6** — полная поддержка: dual-stack DNS, IPv6 SO_ORIGINAL_DST, Telegram DC IPv6 CIDR
- **Игровой режим** — UDP для игр (Roblox и др.), autocircular на портах 1024-65535

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
sh -c '
tmp=/tmp/z2k.sh
rm -f "$tmp"
for url in \
  "https://raw.githubusercontent.com/necronicle/z2k/master/z2k.sh" \
  "https://cdn.jsdelivr.net/gh/necronicle/z2k@master/z2k.sh" \
  "https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/master/z2k.sh"
do
  echo "[i] Пробую: $url" >&2
  if curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$tmp"; then
    exec sh "$tmp"
  fi
done
echo "[FAIL] Не удалось скачать z2k.sh ни с одного зеркала" >&2
exit 1
'
```

Эта команда сначала пробует GitHub raw, затем jsdelivr, затем gh-proxy. После запуска `z2k.sh` все внутренние загрузки тоже идут через цепочку зеркал.

---

## Меню

После установки доступно интерактивное меню:

```bash
sh /opt/zapret2/z2k.sh menu
```

| Пункт | Описание |
|---|---|
| **[1]** | Установить/переустановить zapret2 |
| **[2]** | Управление сервисом (старт/стоп/рестарт/статус) |
| **[3]** | Обновить списки доменов |
| **[4]** | Резервная копия/восстановление |
| **[5]** | Удалить zapret2 |
| **[A]** | Режим без хостлистов (Austerusj) — обработка всего TLS-трафика |
| **[W]** | Whitelist — управление списком исключений |
| **[R]** | RST-фильтр — фильтрация аномальных TCP RST |
| **[F]** | Silent fallback — ускоренная ротация при отсутствии ответа |
| **[G]** | Игровой режим (Roblox и др.) |
| **[T]** | Telegram |
| **[S]** | Скрипты custom.d |
| **[P]** | Веб-панель (дубль меню в браузере) |
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
- **UDP детектор** — соотношение отправленных/полученных пакетов (4+ out, ≤1 in = неудача)
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

Встроенная веб-панель для просмотра состояния через браузер.

Установка через меню z2k:

1. Запустить меню: `sh /opt/zapret2/z2k.sh menu`
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
sh -c '
tmp=/tmp/z2k_cleanup.sh
rm -f "$tmp"
for url in \
  "https://raw.githubusercontent.com/necronicle/z2k/master/z2k_cleanup.sh" \
  "https://cdn.jsdelivr.net/gh/necronicle/z2k@master/z2k_cleanup.sh" \
  "https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/master/z2k_cleanup.sh"
do
  echo "[i] Пробую: $url" >&2
  if curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$tmp"; then
    exec sh "$tmp"
  fi
done
echo "[FAIL] Не удалось скачать z2k_cleanup.sh ни с одного зеркала" >&2
exit 1
'
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
├── strats_new2.txt             # TCP strategy database (RKN 45 / YT 22 / GV 22)
├── quic_strats.ini             # UDP/QUIC strategy database (yt_quic + discord_voice)
├── lib/                        # Core modules (загружаются z2k.sh)
│   ├── utils.sh                # Utilities, safe_config_read, z2k_fetch с 5-layer fallback
│   ├── system_init.sh          # System detection
│   ├── install.sh              # 14-step install + rollback
│   ├── strategies.sh           # Strategy parsing & management
│   ├── config.sh               # Configuration management
│   ├── config_official.sh      # nfqws2 config generation
│   ├── webpanel.sh             # CGI веб-панель installer
│   └── menu.sh                 # Interactive menu (16 опций)
├── files/
│   ├── S99zapret2.new          # Init script
│   ├── 000-zapret2.sh          # ndmc hook
│   ├── init.d/                 # Дополнительные init-скрипты (TG watchdog и др.)
│   ├── ndm/                    # Keenetic ndmc-интеграция
│   ├── fake/                   # Binary protocol blobs (85 файлов)
│   ├── lua/
│   │   ├── z2k-autocircular.lua    # Persistent strategy memory + telemetry
│   │   └── z2k-modern-core.lua     # IP frag, QUIC morph, TLS shuffle, ECH
│   ├── lists/                  # Domain & IP lists (RKN, YouTube, Discord, AWS, Roblox, TG)
│   ├── z2k-healthcheck.sh      # Service availability monitoring
│   ├── z2k-config-validator.sh # Config validation
│   ├── z2k-update-lists.sh     # Auto domain list updater
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
├── tests/                      # Test framework
│   ├── run_all.sh              # Test runner
│   ├── test_utils.sh           # Utils tests
│   ├── test_strategies.sh      # Strategy tests
│   ├── test_config_official.sh # Config gen tests
│   └── test_validator.sh       # Validator tests
└── .github/workflows/
    ├── ci.yml                  # shellcheck + go + luacheck + cross-arch build
    └── jsdelivr-purge.yml      # Сбросить jsdelivr CDN после релиза
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
