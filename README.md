# z2k — Zapret2 для Keenetic

**Telegram-группа: [@zapret2keenetic](https://t.me/zapret2keenetic)** — вопросы, помощь с настройкой, обсуждение

Поддержать проект:

- TON: `UQA6Y6Mf1Qge2dVSl3_vSqb29SKrhI8VgJtoRBjgp08oB8QY`
- USDT (ERC20): `0xA1D6d7d339f05C1560ecAF0c5CB8c4dc80Dc46A9`
- USDT (TRC20): `TVtWDryrowtb4MYGGtA8Q2yCAei4VFh5g5`

## Огромная благодарность спонсорам проекта

- **SupWgeneral**
- **Alexey**
- **Jet_sk_ya**
- **Suharik39**
- **ZyaK<-**
- **Алексей Стрельцов**
- **Diman86RUS**
- **Alex**
- **GRM**

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
  - **RKN** — список ресурсов (TCP/TLS + HTTP) — 50 стратегий
  - **YouTube TCP** — youtube.com и связанные домены — 22 стратегии
  - **YouTube GV** — googlevideo CDN (стриминг) — 22 стратегии
- QUIC autocircular профили: YouTube QUIC (UDP/443) и Discord voice — с z2k morph-стратегиями (QUIC morph / timing morph)
- Discord профили:
  - TCP: hostlist Discord включён в RKN-профиль
  - UDP voice/video: `circular` с `allow_nohost` — стратегия закрепляется через autocircular `state.tsv` после первого успеха (рабочая стратегия удерживается между restart'ами)
- ECH (Encrypted Client Hello) detection — автоматический пропуск desync когда SNI зашифрован
- Hostlist режим: стратегии применяются только к доменам из списков
- Whitelist: домены-исключения (госуслуги, банки, Steam / PlayStation / Nintendo / Epic, VK, Яндекс и др.) не обрабатываются — к ним desync не применяется

### Сеть и прокси

- **Telegram** — прозрачная работа для всех устройств в сети, без настройки на клиентах
- **IPv6** — полная поддержка: dual-stack DNS, IPv6 SO_ORIGINAL_DST, Telegram DC IPv6 CIDR
- **Игровой режим (WARP)** — игры, заблокированные по IP (не по домену), обходятся через split-туннель Cloudflare WARP; списки игровых IP/CIDR редактируются в вебморде. Подробнее — раздел [«Игровой режим (WARP)»](#игровой-режим-warp) ниже.

### Инструменты и мониторинг

- **Веб-панель** — мониторинг через браузер (CGI): статус сервиса, стратегии, логи
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

### 1) Компоненты прошивки Keenetic

**«Модули ядра подсистемы Netfilter» нужны на ЛЮБОЙ прошивке Keenetic** — по умолчанию они не предустановлены, и без них z2k не запустится. Их нужно доустановить в веб-интерфейсе Keenetic (раздел «Изменить набор компонентов»):

1. **«Модули ядра подсистемы Netfilter»** — обязательно, на всех прошивках и роутерах.
2. **«Протокол IPv6»** — нужен только на старых прошивках (и только если вы используете IPv6). На новых прошивках IPv6 уже включён по умолчанию, и такого пункта в списке может не быть.

На части прошивок пункт «Модули ядра подсистемы Netfilter» появляется в списке только после того, как выбран компонент «Протокол IPv6».

### 2) Подготовка USB и установка Entware (обязательно)

Подготовьте USB-накопитель и установите Entware по официальной инструкции Keenetic:
https://help.keenetic.com/hc/ru/articles/360021214160

После установки Entware выполните обновление индекса пакетов и установите зависимости:

```bash
opkg update
opkg install coreutils-sort curl grep gzip ipset iptables kmod_ndms xtables-addons_legacy libnghttp2 openssl-util
```

### 3) Установка z2k

```bash
{ curl --resolve raw.githubusercontent.com:443:213.176.74.63 -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh || curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh; } | sh
```

---

## Меню

Меню открывается **той же командой, что и установка** — если z2k уже установлен, она просто открывает меню (а если ещё нет — ставит и открывает):

```bash
{ curl --resolve raw.githubusercontent.com:443:213.176.74.63 -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh || curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh; } | sh
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
| **[E]** | Игровой режим WARP (Cloudflare-туннель для игр, заблоченных по IP) |
| **[T]** | Telegram прокси |
| **[S]** | Скрипты custom.d |
| **[P]** | Веб-панель |
| **[D]** | Диагностика (сводка для траблшутинга) |
| **[I]** | Убрать статические IP Instagram (обход DNS-отравления) |
| **[Y]** | Diagnose domain — 4-стадийная проба + рекомендация |
| **[M]** | Динамический TTL для fake-пакетов — выключить для мобильных операторов |
| **[A]** | Политика доступа Keenetic — фильтр устройств по NDM-политике (PBR) |
| **[C]** | Сбор статистики стратегий (анонимно) |
| **[H]** | Аппаратный offload — per-flow исключение (нативная ротация на Keenetic) |

---

## Автодетекция (z2k-detect)

`z2k-detect` — фоновый Go-демон z2k для проактивного обнаружения DPI-блокировок.
Заменил сломанные `z2k-probe` / `z2k-classify`. **По умолчанию выключен** — включается оператором в меню `[Y]`.

**Как работает:**
1. Слушает DNS-запросы клиентов. Источник наблюдения авто-детектится: AdGuardHome querylog → dnsmasq.log → AF_PACKET sniff на UDP/53 (универсальный fallback, работает без логов)
2. На каждый новый домен — 4-стадийная проба: DNS → TCP:443 → TLS → HTTP read 32KB
3. Классификация по 22 типизированным кодам (`tls_garbage`, `http_cutoff`, `mtls_required`, `tcp_refused`, ...)
4. Решение:
   - **HOT** — путь до сервера не работает → домен дописывается в `discovered-domains.txt`, nfqws2 подхватывает inotify, следующий запрос юзера уже через bypass
   - **IGNORE** — DNS не резолвится / сервер сам отказал политикой (typed TLS alert / mTLS)

**Управление:**
- Меню `[Y]` — статус, диагностика конкретного домена, toggle on/off
- `Z2K_DISCOVER=0|1` в `/opt/zapret2/config` — флаг автозапуска
- Логи: `/var/log/z2k-detect.log`
- State: только in-memory + сам `discovered-domains.txt`. Никаких отдельных state-файлов на диске.

---

## Динамический TTL (`Z2K_DYNAMIC_TTL`)

z2k автоматически инжектит `:fool=z2k_dynamic_ttl` в каждую fake-стратегию (`fake`, `fakedsplit`, `fakeddisorder`, `hostfakesplit`) TCP-профилей `rkn_tcp` / `yt_tcp` / `gv_tcp`. Lua-hook (`files/lua/z2k-fooling-ext.lua`) перед отправкой fake-пакета ставит ему `ip_ttl = (TTL реального исходящего пакета) − 1`, чтобы fake выглядел как обычный клиентский пакет с точки зрения ТСПУ. Жёстко прибитый `ip_ttl=8` от роутера в 50+ хопах от назначения сразу палится — `dynamic_ttl` это закрывает.

**Когда выключать (меню `[M]` → `Выключить` или `Z2K_DYNAMIC_TTL=0` в `/opt/zapret2/config`):**
- Мобильные операторы с запретом раздачи (МТС, Билайн), когда на роутере включён NDM TTL-fix (`ip ttl-fix` через Keenetic CLI) и используется телефонная симка под маскировкой IMEI. В этой топологии NDM всё равно перебивает TTL всех исходящих на фиксированное значение, поэтому наш inject в `POSTROUTING` не доживает до провода — становится чистым per-fake lua-call overhead на слабом MIPS.
- Если speedtest показывает резкую деградацию throughput при включённом z2k и `top` показывает `nfqws2` под потолком CPU — это первый кандидат на опт-аут.

**По умолчанию включён** (`Z2K_DYNAMIC_TTL=1`). Значение переживает `z2k update` / reinstall. Меню `[M]` показывает текущий статус в шапке только если выключен.

---

## Командная строка

**Меню и установка — только через curl-команду** (см. разделы «Установка» / «Меню» выше). Локально меню не запускается.

После установки в `/opt/bin/` есть короткая команда `z2k` для прочих операций:

```bash
z2k <команда>
```

| Команда | Описание |
|---|---|
| `uninstall` | Удалить zapret2 (снимает и TG tunnel) |
| `status`, `s` | Показать статус системы |
| `check`, `info` | Показать какие списки обрабатываются |
| `diag`, `d` | Одностраничная сводка для траблшутинга |
| `update`, `u` | Обновить z2k до последней версии |
| `rollback` | Откатить конфигурацию к snapshot |
| `snapshot` | Создать snapshot конфигурации |
| `validate` | Валидация текущей конфигурации |
| `cleanup` | Очистить старые бэкапы (оставить 5) |
| `version`, `v` | Показать версию |
| `help`, `h` | Показать справку |

---

## Как работает autocircular

Каждый TCP/QUIC профиль содержит N стратегий с номерами `strategy=1..N`. Модуль `circular` в nfqws2 отслеживает успех/неудачу per-domain и переключается на следующую стратегию при неудаче. Успешная стратегия закрепляется.

> **Аппаратный офлоад Keenetic.** На части устройств (особенно ТВ-приставках и Smart TV) NAT-офлоад уводил соединение мимо conntrack, из-за чего десинк к нему не применялся и сайт молча не открывался, а ротация «залипала». z2k при старте сервиса выключает софт-фастпас (`nf_conntrack_fastnat`), поэтому обход и автоподбор стратегий работают и на офлоадных устройствах.

### Детекция неудач

- **Стандартный детектор** — TCP ретрансмиссии и аномальные RST
- **UDP детектор** — соотношение отправленных/полученных пакетов (4+ out, ≤1 in = неудача)
- **TLS alert детектор** (`z2k_tls_alert_fatal`) — анализирует TLS alert + HTTP redirect
- **Mid-stream stall детектор** (`z2k_mid_stream_stall`) — ловит «тихие» разрывы посередине потока, когда DPI режет соединение без RST/alert
- **3-state HTTP classifier** — отличает positive/neutral/hard_fail на HTTP-ответе (с `inseq=18000` и `no_http_redirect`), чтобы не зачитывать редирект на блок-страницу как успех
- **IP block detector** (`--ipblock-detect=on` в nfqws2) — если 3+ ClientHello к одному IP не получают ответа, шлёт client RST чтобы приложение быстро переключилось на другой IP

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

1. Открыть меню через curl (раздел «Меню» выше — та же команда установки открывает меню)
2. Выбрать `[P]` → `[1]` (Установить/Переустановить)

После установки панель доступна в локальной сети по адресу `http://ROUTER_IP:8088/` (порт 8088, без авторизации).

Разделы панели: **Дашборд** (статус сервиса, текущие стратегии, системная информация, rollback-snapshot), **Режимы** (переключатели функций), **WARP** (списки игровых IP — см. ниже), **Whitelist** (домены-исключения), **Доп. домены** (свой список доменов для обхода), **Rotator** (состояние автоподбора и ручное управление), **Логи**, **Диагностика**, **Geosite** (импорт ru-blocked), **Благодарности**.

### Управление ротацией («Состояние ротатора»)

В разделе «Состояние ротатора» можно не только наблюдать подбор стратегий, но и управлять им для каждого домена:

- **Ручной выбор стратегии** — в выпадающем списке напротив домена выбрать любую стратегию из пула категории (проскочить заведомо нерабочую, протестировать свою, закрепить понравившуюся). Применяется на лету (~2 с); автоподбор при этом продолжается.
- **Заморозка 🔒** — кнопка-замок фиксирует строку на текущей стратегии: автоподбор перестаёт её менять. Повторное нажатие — разморозка, ротация возобновляется.
- **Голос Discord** — отдельный селектор над таблицей для стратегии Discord-войса (работает даже до первого голосового подключения).
- **× (сброс)** — вернуть строку к стратегии 1 и режиму «авто».

Ручной выбор и заморозка сохраняются и переживают перезагрузку роутера и обновление z2k. Выпадающий список всегда показывает **полный набор** стратегий категории.

### WARP — списки игровых IP

Раздел «WARP» управляет ipset'ом игрового трафика (см. [«Игровой режим (WARP)»](#игровой-режим-warp)):

- **Тумблер WARP** — включает/выключает split-туннель (переехал сюда из «Режимов»).
- **Списки** — просмотр и правка пользовательских списков IP/CIDR: дописать строки, удалить, отредактировать целиком, выгрузить список в `.txt` и загрузить свой.
- Изменения применяются на лету; ваши правки не затираются автообновлением базового списка.

---

## Telegram

Telegram работает для всех устройств в сети автоматически, без настройки на клиентах. Включается при установке или через меню `[T]`.

---

## Игровой режим (WARP)

Часть игр блокируется по **IP-адресам серверов** (а не по домену/SNI) — пакетный обход (desync) тут бессилен. Для таких игр z2k поднимает **split-туннель через Cloudflare WARP**: трафик к игровым серверам из списка заворачивается в MASQUE-туннель (пакет `usque`, интерфейс `opkgtun0`), а весь остальной трафик роутера идёт напрямую. Десинка и ротатора здесь нет — только маршрутизация нужных подсетей в туннель.

- **Базовый список** — ipset `z2k_warp`, ~14 тыс. CIDR. Берётся из открытого проекта [`medvedeff-true/ru-gaming-blocklist`](https://github.com/medvedeff-true/ru-gaming-blocklist) и обновляется автоматически (upstream освежается примерно каждые 3 часа).
- **Свои списки** — в разделе вебморды «WARP» можно вести собственные IP/CIDR: добавлять, удалять, редактировать, выгружать и загружать `.txt`. Ваши правки к базовому списку сохраняются при его обновлении (3-way merge — ни удаления, ни добавления не затираются).
- **Включение** — тумблером в разделе «WARP» вебморды либо пунктом меню `[E]`. Пакет `usque` z2k ставит сам при первом включении.

---

## Discord — голосовые каналы (фикс на ПК)

Веб и текст Discord z2k тянет на роутере сам. А вот **голос** иногда виснет на «Connecting» — провайдер душит финские голосовые серверы Discord. На уровне роутера это не лечится (нужно было бы ~200 DNS-записей — почти весь лимит Keenetic), поэтому фикс делается **на самом ПК**: пином финского диапазона в hosts-файл на рабочий Cloudflare-адрес.

**Готовый список** (200 строк `finlandNNNNN.discord.media` → `104.25.158.178`):

- скачать: `https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/extras/discord-voice-hosts.txt`
- зеркало: `https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/extras/discord-voice-hosts.txt`

**Куда добавить** (строки из файла — в конец системного hosts):

- **Windows:** `C:\Windows\System32\drivers\etc\hosts` — открыть Блокнотом **от имени администратора**.
- **Linux / macOS:** `/etc/hosts` — через `sudo`.

**После правки** — сбросить DNS-кэш и перезапустить Discord:

- Windows: `ipconfig /flushdns`
- Linux: `sudo resolvectl flush-caches`
- macOS: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`

Адрес `104.25.158.178` со временем может смениться. Если голос снова отвалился — скачайте список заново (свежий держит проект `Flowseal/zapret-discord-youtube`, кнопка «Update hosts file»).

---

## Пользовательские домены

В большинстве случаев чтобы заблокированный сайт начал обходиться через z2k — достаточно добавить его в **extra-список**, без всяких кастомных стратегий. autocircular сам подберёт рабочую стратегию из существующего пула (~50 вариантов для TCP, ~9 для QUIC) и закрепит её в `state.tsv` после первого успеха.

Файл со списком:
```
/opt/zapret2/lists/extra-domains.txt
```

Формат: один домен на строку, без `http://` / `www.`, поддоменов писать не надо (`example.com` автоматически покрывает `foo.example.com`):
```
forum.ru-board.com
example.com
some-blocked-site.org
```

После редактирования файл подхватывается **live, без перезапуска** сервиса z2k (см. ниже про политику апдейтов хост-листов). Через несколько секунд z2k начнёт пытаться обходить блокировку на этих доменах через стандартные стратегии rkn_tcp/yt_tcp/quic в зависимости от трафика.

Стандартные списки (RKN-блок, YouTube, Discord, Instagram, etc.) обновляются автоматически по cron-у в 04:00 и через меню → `[3] Обновить списки доменов`. Свои добавки в `extra-domains.txt` через обновление не перезаписываются.

---

## Пользовательские стратегии (продвинутое)

> Этот раздел нужен **только** если базовый пул стратегий не справился с вашим доменом (редкость). В 90% случаев достаточно добавить домен в [extra-domains.txt](#пользовательские-домены) и autocircular найдёт стратегию автоматически.

Для добавления собственных стратегий без модификации основного кода создайте файлы в директории:

```
/opt/zapret2/extra_strats/custom_strategies.d/
```

Формат файла: `CATEGORY_PROTOCOL.conf` (например `MYSITE_TCP.conf`), содержимое — параметры nfqws2.

**Имя категории должно быть в `[A-Z0-9_]+`** (только латинские заглавные, цифры, подчёркивания). Точки, дефисы и кириллица в имени не поддерживаются — они попадут в путь `extra_strats/<PROTO>/<CATEGORY>/Strategy.txt` и сломают валидатор/генератор. Если домен называется например `forum.ru-board.com`, файл должен быть `RUBOARD_TCP.conf`, а не `FORUM.RU-BOARD.COM_TCP.conf`.

После добавления файла нужен перезапуск сервиса:
```bash
/opt/etc/init.d/S99zapret2 restart
```

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
{ curl --resolve raw.githubusercontent.com:443:213.176.74.63 -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh || curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh; } | sh
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
├── strats_new2.txt             # TCP strategy database (RKN 50 / YT 22 / GV 22)
├── quic_strats.ini             # UDP/QUIC strategy database (yt_quic + discord_voice)
├── lib/                        # Core modules (загружаются z2k.sh)
│   ├── utils.sh                # Utilities, safe_config_read, z2k_fetch с 5-layer fallback
│   ├── system_init.sh          # System detection
│   ├── install.sh              # 16-step install + rollback
│   ├── strategies.sh           # Strategy parsing & management
│   ├── config.sh               # Configuration management
│   ├── config_official.sh      # nfqws2 config generation
│   ├── webpanel.sh             # CGI веб-панель installer
│   ├── menu.sh                 # Interactive menu (20 опций)
│   └── auto_update.sh          # Self-update z2k через UPDATES.json
├── files/
│   ├── S99zapret2.new          # Init script
│   ├── 000-zapret2.sh          # ndmc hook
│   ├── init.d/                 # Дополнительные init-скрипты (TG watchdog и др.)
│   ├── ndm/                    # Keenetic ndmc-интеграция
│   ├── fake/                   # Binary protocol blobs
│   ├── lua/
│   │   ├── z2k-state-persist.lua   # Persistent strategy memory (state.tsv)
│   │   ├── z2k-detectors.lua       # Failure detectors (TLS alert, mid-stream stall, ...)
│   │   ├── z2k-modern-core.lua     # IP frag, QUIC morph, TLS shuffle, ECH
│   │   ├── z2k-fooling-ext.lua     # Dynamic-TTL fooling hook
│   │   ├── z2k-http-strats.lua     # HTTP-layer strategy helpers
│   │   └── z2k-range-rand.lua      # Randomised range injection
│   ├── lists/                  # Domain & IP lists (RKN, YouTube, Telegram, WARP game IPs, extra-domains)
│   ├── z2k-warp.sh             # Game-mode WARP split-tunnel (routing)
│   ├── z2k-scheduler.sh        # Periodic tasks (list update, self-heal) — replaces cron
│   ├── z2k-config-validator.sh # Config validation
│   ├── z2k-update-lists.sh     # Auto domain list updater
│   ├── z2k-auto-update.sh      # Self-update cron entry
│   ├── z2k-geosite.sh          # Geosite ru-blocked import
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
├── tests/                      # Test framework (lua + shell fixtures, see tests/run_all.sh)
└── .github/workflows/
    ├── ci.yml                  # shellcheck + go + luacheck + cross-arch build
    └── jsdelivr-purge.yml      # Сбросить jsdelivr CDN после релиза
```

---

## Примечания

- Если вы используете IPv6 в сети, убедитесь что он включён в прошивке (см. требования выше).
- Автообновление списков доменов — через cron (`/opt/zapret2/z2k-update-lists.sh`).
- Если конкретный сайт не открывается — добавь домен в `/opt/zapret2/lists/extra-domains.txt` (через webpanel «Доп. домены» или вручную); autocircular подберёт страту в течение нескольких TLS-handshake'ов.
- `RST_FILTER` по умолчанию выключен для совместимости с Cloudflare; если у провайдера подтверждены fake-RST инжекты ТСПУ, добавь `RST_FILTER=1` в `/opt/zapret2/config` и перезапусти сервис.
- Для траблшутинга пришли вывод `z2k diag` — это одностраничная сводка о состоянии всех компонентов.
- Валидация конфигурации: `z2k validate`. Откат: `z2k rollback`.

---

## Лицензия

MIT
