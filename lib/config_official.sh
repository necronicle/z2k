#!/bin/sh
# lib/config_official.sh - Генерация официального config файла для zapret2
# Адаптировано для z2k с multi-profile стратегиями

# Окно перехвата UDP — сколько пакетов потока уходит в очередь.
# Обоснование значений — у места, где они попадают в config (ищи
# NFQWS2_UDP_PKT_OUT). Здесь они лежат на уровне файла, а не внутри функции,
# потому что их читают две разные: одна строит стратегии и сверяет с ними
# пороги детекторов, другая пишет config.
Z2K_UDP_PKT_OUT="8"
Z2K_UDP_PKT_IN="8"

# ==============================================================================
# ГЕНЕРАЦИЯ NFQWS2_OPT ИЗ СТРАТЕГИЙ Z2K
# ==============================================================================

generate_nfqws2_opt_from_strategies() {
    # Генерирует NFQWS2_OPT для config файла на основе текущих стратегий

    # Pre-utils-safe path resolution. Original design hardcoded all three
    # in case the function got called before utils.sh sourced; we now derive
    # extra_strats_dir/lists_dir from ZAPRET2_DIR with the same /opt/zapret2
    # fallback (parameter-expansion is evaluated lazily, so this stays a
    # no-op in production where ZAPRET2_DIR is either unset or already set
    # to /opt/zapret2 by utils.sh). Tests can mock these by exporting
    # ZAPRET2_DIR before invocation. Третьей переменной, config_dir, здесь больше
    # нет: /opt/etc/zapret2 нужен был только ветке Austerus, снятой 2026-08-04.
    local extra_strats_dir="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats"
    local lists_dir="${ZAPRET2_DIR:-/opt/zapret2}/lists"

    # Режим Austerusj (all_tcp443.conf) СНЯТ 2026-08-04. Пункт меню, которым его
    # включали, убрали ещё 2026-04-15 (96c24a9), а ветку в генераторе оставили —
    # получился режим, который нельзя включить, но который продолжал работать у
    # всех, кто успел его включить до апреля. И работал он разрушительно: ветка
    # закорачивала ВСЮ генерацию конфига через `return 0`, так что роутер получал
    # три строки стратегий из Zapret1 вместо хостлистов, whitelist'а и circular —
    # то есть единственное место в z2k, где --hostlist-exclude=whitelist.txt не
    # действовал вообще (сюда же упирался вопрос «почему keenetic-домены не
    # исключаются»). Выйти из режима было нельзя ничем: файл лежит в
    # /opt/etc/zapret2, а reinstall меняет /opt/zapret2, и пересоздавался он
    # только при отсутствии. Миграция, снимающая режим у затронутых, —
    # migrate_drop_austerus_mode() в lib/install.sh.

    # Загрузить текущие стратегии из категорий
    local youtube_tcp=""
    local youtube_gv_tcp=""
    local rkn_tcp=""
    local quic_udp=""
    local discord_udp=""

    # Variant-A refactor feature flags. Осталась одна фаза — остальные снялись
    # вместе с профилями, которые они гейтили:
    #   PHASE1 (webrtc_bypass) — профиль удалён, см. комментарий ниже по файлу;
    #   PHASE2 (слияние game_udp + game_catchall) — игровой режим переехал на
    #           WARP в r-61.1, профилей больше нет;
    #   PHASE4 (cdn_tls) — снят 2026-04-27, см. ниже.
    local Z2K_REFACTOR_PHASE3
    # Phase 3 (YT+GV merge into google_tls) — DEFAULT OFF as of 2026-04-26.
    # Field reports на enhanced (Сергей #2191, others) показали падение
    # YouTube performance после merge; раздельные yt + googlevideo
    # профили работают надёжнее. Pre-merge legacy code path (else
    # branch ниже) теперь default. Юзеры могут опционально включить
    # merge через `Z2K_REFACTOR_PHASE3=1` в config — оставлено для
    # тестирования / возможного rollforward.
    Z2K_REFACTOR_PHASE3=$(safe_config_read "Z2K_REFACTOR_PHASE3" "/opt/zapret2/config" "0")
    # Phase 4 (cdn_tls) удалён 2026-04-27 — отдельный CF/OVH/Hetzner/DO
    # профиль перехватывал non-RKN CF трафик и применял свой набор стратегий
    # слабее проверенного 47-стратегий rkn_tcp rotator'а. CF возвращается
    # под rkn_tcp как было до Variant A refactor'а.

    # Z2K_USE_MID_STREAM_DETECTOR (default 1, per Mark 2026-05-02 policy):
    # bundle flag for the
    # rkn_tcp mid-stream stall detector wiring. Off: rkn_tcp keeps
    # its master-compatible layout (--in-range=-s5556 +
    # failure_detector=z2k_tls_stalled), which is what the field
    # currently runs. On: bumps rkn_tcp to --in-range=-s20000 AND
    # switches its failure_detector to z2k_mid_stream_stall (the
    # byte-window v3 state machine landed in 14984c3). Both knobs
    # belong to the same rotation behavior — flipping one without
    # the other produces a half-state (lua sees more body but the
    # active detector still ignores it, or the byte-window detector
    # is wired but blind because its observation cap is still 5.5K).
    # Tests assert the two move together.
    local Z2K_USE_MID_STREAM_DETECTOR
    Z2K_USE_MID_STREAM_DETECTOR=$(safe_config_read "Z2K_USE_MID_STREAM_DETECTOR" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")

    # Пользовательские стратегии на пул — user-owned, переживают всё.
    #
    # Читается ПРИ КАЖДОЙ перегенерации конфига, а не запекается один раз: иначе
    # первый же toggle в панели или auto-update молча вернул бы shipped-строку, и
    # человек остался бы с чужой стратегией, думая, что работает его.
    #
    # Живёт отдельно от shipped Strategy.txt намеренно. Правки shipped-файлов у
    # нас затираются обновлением by design («проект автоматизации»), поэтому
    # редактор, пишущий туда, отдавал бы результат, исчезающий через релиз.
    # Здесь же — тот же класс, что whitelist и extra-domains: install.sh
    # сохраняет каталог при переустановке.
    #
    # Ротация для такого пула выключается сама собой: директива circular входит в
    # саму строку стратегии, и строка пользователя заменяет её целиком. Не написал
    # circular — не будет ротации, ровно как он и просил.
    # Файл стратегий цел? USB-флешка умеет тихо отдавать вместо содержимого
    # сплошные 0xFF (мёртвый блок NAND: размер и mtime целы, данных нет —
    # полевой случай 2026-08-06, роутер владельца, два файла из трёх). Такой
    # мусор, попав в обработку NFQWS2_OPT, вешает генерацию в бесконечный цикл
    # и пишет на диск конфиг-мину, которая роняет nfqws2 на следующем рестарте.
    #
    # Сама проверка живёт в lib/utils.sh на верхнем уровне: её зовёт не только
    # генерация конфига, но и диагностика, а две копии одной проверки расходятся
    # молча. Вложенная копия была вдобавок недоступна снаружи вообще.
    #
    # Здесь остаётся гард на её отсутствие: вебпанель (webpanel/cgi/actions.sh,
    # _gen_libs_source) сорсит utils.sh УСЛОВНО, и на обрезанном дереве сюда
    # входят без него. Проверить нечем — но и отказывать в генерации нельзя:
    # тогда недостающая библиотека гасила бы любой тумблер панели на исправном
    # роутере. Смысловую валидность ниже по функции всё равно ловит nfqws2
    # --dry-run.
    _z2k_file_sane() {
        command -v z2k_strategy_file_sane >/dev/null 2>&1 || return 0
        z2k_strategy_file_sane "$1"
    }

    z2k_custom_strategy() {
        # z2k_custom_strategy <pool> -> печатает строку пользователя, если она есть
        local _cs_dir="${ZAPRET2_DIR:-/opt/zapret2}/lists/custom-strategies"
        local _cs_file="$_cs_dir/$1.txt"
        [ -s "$_cs_file" ] || return 1
        # Комментарии и пустые строки выкинуть, остальное склеить в одну строку:
        # nfqws2 принимает опции одной строкой, а человек может разложить их
        # построчно для читаемости.
        awk '{ sub(/\r$/,""); sub(/^[[:space:]]*#.*$/,"") } NF { printf "%s ", $0 }' "$_cs_file" \
            | sed 's/[[:space:]]*$//'
    }

    # Порченый файл = генерация честно падает, старый конфиг и работающий
    # сервис не тронуты (fail-closed).
    z2k_read_pool_strategy() {
        # z2k_read_pool_strategy <file> — содержимое в stdout, либо rc=1
        local _f="$1"
        if ! _z2k_file_sane "$_f"; then
            print_error "Файл стратегий повреждён (бинарный мусор вместо опций): $_f"
            print_error "Генерация конфига остановлена, старый конфиг сохранён. Лечится обновлением/переустановкой z2k."
            return 1
        fi
        cat "$_f"
    }

    # Пользовательские стратегии лежат на ТОЙ ЖЕ флешке и ПЕРЕКРЫВАЮТ пуловые
    # (см. присваивания ниже), поэтому одной проверки пуловых файлов мало: гнилой
    # блок под custom-strategies вернул бы ровно то же зависание через чёрный ход.
    # Проверяем их все разом ДО первого использования — так отказ один и тот же
    # (fail-closed), а не «часть пулов подхватилась, часть нет».
    for _cs_pool in yt_tcp gv_tcp rkn_tcp yt_quic; do
        _cs_check="${ZAPRET2_DIR:-/opt/zapret2}/lists/custom-strategies/${_cs_pool}.txt"
        [ -s "$_cs_check" ] || continue
        if ! _z2k_file_sane "$_cs_check"; then
            print_error "Пользовательский файл стратегий повреждён (бинарный мусор вместо опций): $_cs_check"
            print_error "Генерация конфига остановлена, старый конфиг сохранён. Исправьте или удалите этот файл."
            return 1
        fi
    done

    # Прочитать стратегии из файлов категорий
    if [ -f "${extra_strats_dir}/TCP/YT/Strategy.txt" ]; then
        youtube_tcp=$(z2k_read_pool_strategy "${extra_strats_dir}/TCP/YT/Strategy.txt") || return 1
    fi
    _cs=$(z2k_custom_strategy yt_tcp) && [ -n "$_cs" ] && youtube_tcp="$_cs"

    if [ -f "${extra_strats_dir}/TCP/YT_GV/Strategy.txt" ]; then
        youtube_gv_tcp=$(z2k_read_pool_strategy "${extra_strats_dir}/TCP/YT_GV/Strategy.txt") || return 1
    fi
    _cs=$(z2k_custom_strategy gv_tcp) && [ -n "$_cs" ] && youtube_gv_tcp="$_cs"

    if [ -f "${extra_strats_dir}/TCP/RKN/Strategy.txt" ]; then
        rkn_tcp=$(z2k_read_pool_strategy "${extra_strats_dir}/TCP/RKN/Strategy.txt") || return 1
    fi
    _cs=$(z2k_custom_strategy rkn_tcp) && [ -n "$_cs" ] && rkn_tcp="$_cs"

    # YouTube QUIC autocircular fallback (13 strategies). Proven fake-blob escalation
    # first; experimental z2k morphs demoted to the tail (slots 11-13). This inline is
    # only the cold-start default — extra_strats/UDP/YT/Strategy.txt (from quic_strats.ini)
    # overrides it on any real install (see below). key=yt_quic stable key; nld=2 cuts CDN churn.
    # udp_in=3, udp_out=5 (было 8/4 с 2026-06-08, до того 1/4).
    #
    # Замер 2026-08-19, 1646 QUIC-потоков из журнала боевого роутера разбил
    # посылку, на которой стояла июньская правка. Мёртвый QUIC-поток шлёт
    # МЕНЬШЕ пакетов, чем живой, а не больше: браузер не долбится в стену, а
    # отправляет Initial, ждёт и откатывается на TCP:
    #     мёртвые (402):  1 пакет 57, 2 пакета 222, 3+ — остальные
    #     живые (1239):  до третьего входящего успевают отправить 2-5
    # Значит «pos_out>=N = клиент ретрансмитит Initial = блокировка» неверно, и
    # порогом по числу исходящих эти два класса не разделяются вообще.
    #
    # Спасает схему только сброс счётчика по успеху: ротация идёт, только если три
    # провала подряд не разбавлены ни одним успехом. При udp_in=8 успех не
    # срабатывает практически никогда — тормоза нет. Симуляция счётчика на том же
    # журнале (трафик был здоровый, 235 живых потоков из 237):
    #     udp_in=8 udp_out=4  ->  15 ротаций, 58 ложных провалов,   1 успех
    #     udp_in=3 udp_out=5  ->   1 ротация,   7 ложных провалов, 228 успехов
    # (оценка ротаций нижняя: группировка шла по серверному IP, а реальный ключ
    #  nld=2 объединяет все IP одного домена, там серии длиннее)
    #
    # udp_in=3 — успех требует четырёх входящих. Выше «просочившихся 2-3
    # пакетов», из-за которых правили в июне, и ниже реального ответа сервера:
    # распределение входящих бимодальное (0 либо >=3, полоса 1-2 пуста).
    # udp_out=5 — компромисс там, где разделения нет: 21% отлова мёртвых против
    # 5,5% у шестёрки при том же числе ложных срабатываний.
    #
    # ВАЖНО с 19.08.2026: на yt_quic этот компромисс больше не наступает.
    # Провалы пула считает z2k_fail_quic_silence, и штатному детектору он
    # UDP-пакеты своих пулов НЕ отдаёт — то есть правило «отослано >= udp_out
    # при принято <= udp_in» не выполняется вовсе, и udp_out там инертен.
    # Значение оставлено как есть: оно действует на пулах без нашего детектора
    # и служит документацией порога, если детектор снимут. udp_in продолжает
    # работать — его читает standard_success_detector.
    #
    # Оба порога обязаны лежать ниже окна перехвата NFQWS2_UDP_PKT_IN/OUT —
    # см. комментарий там же. Same change mirrored in quic_strats.ini.
    quic_udp="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=3:udp_out=5:key=yt_quic:nld=2 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:ip_autottl=-2,3-20:strategy=1 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=1 --lua-desync=drop:strategy=1 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=4:ip_autottl=-2,3-20:strategy=2 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=2 --lua-desync=drop:strategy=2 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_rutracker:repeats=6:strategy=3 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=3 --lua-desync=drop:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=6:ip_autottl=-2,3-20:strategy=4 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=6:payload=all:ip_autottl=-2,3-20:strategy=5 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=16:strategy=5 --lua-desync=drop:strategy=5 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=6 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=6 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=7 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=7 --lua-desync=fake:payload=quic_initial:dir=out:blob=0x00000000000000000000000000000000:repeats=2:payload=all:strategy=8 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=8 --lua-desync=drop:strategy=8 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:ip_autottl=-2,3-20:strategy=9 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=24:strategy=9 --lua-desync=drop:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=10 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=12:pad_max=72:strategy=11 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=12 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=85:fakes=2:pad_min=12:pad_max=72:strategy=13"

    # If category strategy files exist, prefer them over hardcoded QUIC defaults.
    _cs=$(z2k_custom_strategy yt_quic) && [ -n "$_cs" ] && quic_udp="$_cs"
    if [ -z "$_cs" ] && [ -f "${extra_strats_dir}/UDP/YT/Strategy.txt" ]; then
        quic_udp=$(z2k_read_pool_strategy "${extra_strats_dir}/UDP/YT/Strategy.txt") || return 1
    fi
    # Discord TCP profiles from zapret4rocket are absent; disable dedicated TCP Discord profile.
    local discord_tcp_block=""

    # Discord UDP (z2k autocircular on the zapret4rocket primitive family).
    # ПО КАНОНУ bol-van: голос+стрим пробиваются МАЛЕНЬКИМ cutoff на старте флоу
    # + connbytes, а НЕ непрерывным фейком. --out-range=-d4 = фейк только на
    # первые 4 data-пакета каждого флоу (#1267: "n2 или d2 лучше всего"; тугой
    # cutoff = меньше пакетов под фейком = безопаснее для стрима). Ключевой
    # принцип bol-van (#4450): "на linux нас спасёт connbytes" — высокобитрейтный
    # медиапоток НЕЛЬЗЯ гнать через NFQUEUE целиком (keepalive это и делал →
    # MIPS-CPU захлёбывался → пинг 5000 на стриме). Просадку голоса bol-van лечит
    # НЕ расширением cutoff'а, а repeats/dup (#6915) — рычаг надёжности в repeats.
    # --payload=discord_ip_discovery,stun — гейтим именно discovery/STUN-сигнатуры
    # (не quic_initial — то для QUIC/443, не для голоса). БЕЗ keepalive (см.
    # NFQWS2_PORTS_UDP_KEEPALIVE ниже — отключён по этой же причине).
    # strategy=1 = базовый fake quic_dbankcloud repeats=10 (рычаг bol-van против
    # просадки голоса — "поиграться репитами" #6915; 10 = рабочий референс юзера);
    # 2-6 — fallback'и (разные repeats/ttl) для circular-перебора, все под d4-cutoff.
    # 2026-04-30: blob мигрирован quic_google → quic_dbankcloud (TSPU
    # фингерпринтит google-QUIC clienthello, dbankcloud обходит надёжнее).
    # hostkey=z2k_nohost_key — нативный hostkey-генератор (z2k-modern-core.lua,
    # через bol-van automate_host_record arg.hostkey). Discord/STUN UDP без SNI
    # → константа "nohost" → shared rotation state autostate[discord_udp][nohost]
    # вместо per-IP фрагментации стокового host_ip fallback'а (иначе Discord
    # voice холодно стартует на каждом новом DC-IP). Нативная замена archived
    # allow_nohost (z2k-autocircular) — алгоритм ротации остаётся circular().
    discord_udp="--filter-udp=50000-50100,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --out-range=-d4 --payload=discord_ip_discovery,stun --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:hostkey=z2k_nohost_key --lua-desync=fake:payload=all:blob=active_discord_udp:repeats=6:strategy=1 --lua-desync=fake:payload=all:blob=active_discord_udp:repeats=5:strategy=2 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=3:strategy=3 --lua-desync=fake:payload=all:blob=active_discord_udp:repeats=3:strategy=3 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=10:strategy=4 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=10:strategy=4 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=3:strategy=5 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=3:strategy=5 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=6:strategy=6 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=6:strategy=6 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=6:strategy=7 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=6:ip_autottl=-2,3-20:strategy=7 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=4:strategy=8 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=4:strategy=8 --lua-desync=fake:payload=discord_ip_discovery:blob=stun:repeats=5:strategy=9 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=5:strategy=9"

    # Дефолт для пула, чей Strategy.txt пуст или нечитаем.
    #
    # ВТОРАЯ ЛИНИЯ ОБОРОНЫ, И СРАБАТЫВАЕТ ОНА ЧАЩЕ ПЕРВОЙ.
    # create_default_strategy_files (lib/strategies.sh) отрабатывает один раз, при
    # установке. Этот путь — при КАЖДОЙ пересборке конфига, то есть при каждом
    # применении стратегий. Сюда попадает роутер, у которого файл испортился уже
    # ПОСЛЕ установки, а нули в Strategy.txt на этом железе случались.
    #
    # Раньше здесь стоял одиночный `fake:blob=fake_default_tls:repeats=6` без
    # circular. Пул терял не только свою технику, но и саму способность перебирать
    # запасные: один приём, и если он не проходит — всё.
    #
    # Аварийный набор берём из lib/utils.sh, чтобы определение было одно. Проверка
    # доступности — на случай путей, где config_official сорсится в одиночку:
    # вебпанель (webpanel/cgi/actions.sh, _gen_libs_source) сорсит utils.sh
    # УСЛОВНО, и на роутере с обрезанным деревом сюда входят без него.
    #
    # ЗАПАСНОЙ ЛИТЕРАЛ — ТОЖЕ РОТИРУЮЩИЙ, И ЭТО НЕСУЩЕЕ. Здесь лежала
    # дореформенная строка: один fake без circular и без key=. Достижима она
    # ровно на том пути, который случается чаще всего — тумблер в панели, — и
    # схлопывала ВСЕ ТРИ TCP-пула в статический фейк с общей ячейкой ротации.
    # В панели такое состояние неотличимо от здорового, то есть человек видел
    # «всё применилось», а обход оставался с одним приёмом без запасных.
    # Строка — дословная копия z2k_emergency_tcp_pool (lib/utils.sh); при
    # правке того набора править и здесь, иначе деградированные пути разъедутся.
    _z2k_pool_default() {
        if command -v z2k_emergency_tcp_pool >/dev/null 2>&1; then
            z2k_emergency_tcp_pool "$1"
        else
            printf '%s' "--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --lua-desync=circular:fails=3:retrans=2:maxseq=16384:time=60:key=$1:nld=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:tls_mod=rnd,dupsid,sni=www.google.com:strategy=1 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,midsld:strategy=1 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1:strategy=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:tcp_ts=-1000:badsum:strategy=3 --lua-desync=fakedsplit:payload=tls_client_hello:dir=out:pos=1:strategy=3"
        fi
    }

    # Использовать дефолт если стратегия пустая. Ключ circular обязан совпадать с
    # боевым, иначе состояние ротации уедет в чужую ячейку.
    [ -z "$youtube_tcp" ] && youtube_tcp=$(_z2k_pool_default yt_tcp)
    [ -z "$youtube_gv_tcp" ] && youtube_gv_tcp=$(_z2k_pool_default gv_tcp)
    [ -z "$rkn_tcp" ] && rkn_tcp=$(_z2k_pool_default rkn_tcp)


    # Force domain-level memory for all autocircular profiles.
    # This prevents churn on frequently changing subdomains.
    ensure_circular_nld2() {
        local input="$1"
        local out=""
        local token=""
        local opts=""
        local part=""
        local rest=""
        local old_ifs="$IFS"

        set -f  # no glob: $input/$opts tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            nld=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:nld=2"
                    else
                        token="--lua-desync=circular:nld=2"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f

        IFS="$old_ifs"
        printf '%s' "$out"
    }

    youtube_tcp=$(ensure_circular_nld2 "$youtube_tcp")
    youtube_gv_tcp=$(ensure_circular_nld2 "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_nld2 "$rkn_tcp")
    quic_udp=$(ensure_circular_nld2 "$quic_udp")

    # Override the default `inseq=4096` on TCP TLS circulars so the
    # standard success_detector does NOT fire prematurely before the
    # community-confirmed TSPU "16KB byte-gate" RST window
    # (typically observed at 12-18KB into the incoming stream — see
    # ntc.party 22516 / Habr 1009560). Source for the threshold
    # mechanic: zapret-auto.lua:236 — incoming `seq > arg.inseq`
    # triggers `standard_success_detector` → `crec.nocheck = true`,
    # at which point a later RST in the same flow is invisible to
    # any failure detector (zapret-auto.lua:261). With inseq=18000
    # success only fires after we've cleared the realistic gate
    # window; if the gate hits at 12-17K we still see the RST as a
    # failure and rotate.
    #
    # Limitation acknowledged: gates above ~18KB are NOT closed by
    # this. Reports of 24-32KB variants exist; those would need a
    # higher inseq, but raising it further also delays legitimate
    # success on small handshakes/payloads.
    #
    # Applied only to TCP TLS profiles (rkn_tcp, yt_tcp, gv_tcp).
    # UDP profiles (quic_udp) use udp_in/udp_out instead
    # of inseq and are left untouched.
    # ── Окно счётчика провалов (`time=`) ─────────────────────────────────────
    #
    # ЗАЧЕМ. `time` — это НЕ окно, в которое должны уложиться все три провала.
    # Мануал: «время в секундах, после которого с момента ПРЕДЫДУЩЕЙ неудачи
    # следующая неудача начинает счет заново». Зазор между соседними.
    #
    # Замер 25-26.08.2026 по одиннадцати дампам с LG webOS (пул yt_tcp, домен
    # www.youtube.com есть в TCP/YT/List.txt). Все десять содержательных
    # потоков — один сценарий: ClientHello, восемь повторов, НОЛЬ входящих
    # байт. Провал детектируется штатно на втором повторе, через 224 мс.
    # Зазоры между попытками телевизора:
    #
    #     151, 135, 129, 69, 235, 188, 108, 72, 116 сек
    #     мин 69   медиана 129   макс 235
    #
    # Годных зазоров при time=60 — НОЛЬ из девяти. Счётчик обнуляется после
    # каждого провала и до fails=3 не доходит никогда. Сквозной прогон
    # настоящего automate_failure_counter по этим зазорам:
    #
    #     time=60  fails=3 -> 0 ротаций      time=180 fails=3 -> 2
    #     time=60  fails=2 -> 0 ротаций      time=300 fails=3 -> 3
    #
    # Снижение fails не даёт НИЧЕГО: при time=60 каждый зазор больше окна.
    # Единственный рычаг — time.
    #
    # ПОЧЕМУ НЕ ВСЕМ ПУЛАМ. Замер распределения потоков (488 штук с боевого
    # роутера) показал: порог успеха защёлкивается на 5% соединений при наших
    # порогах. То есть документированная защита от ложной ротации — «при удаче
    # счетчик сбрасывается» — в поле почти не работает, и реально от неё
    # защищает как раз `time`. Расширяя его, мы ослабляем единственную
    # работающую защиту, поэтому расширяем ТОЛЬКО там, где выигрыш измерен:
    # на пулах видео, где сидят телевизоры и приставки. На rkn/cf/http клиенты
    # это браузеры с плотными попытками, там 60 хватает.
    Z2K_CIRCULAR_TIME_SLOW=300
    ensure_circular_time() {
        local input="$1"
        local target="${2:?ensure_circular_time: значение обязательно}"
        local out="" token="" opts="" part="" rest=""
        local old_ifs="$IFS"

        set -f  # без глоба: токены могут нести *,?,[ ] из правленого Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            time=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:time=${target}"
                    else
                        token="--lua-desync=circular:time=${target}"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    ensure_circular_tcp_inseq() {
        local input="$1"
        local target="${2:-18000}"
        local out=""
        local token=""
        local opts=""
        local part=""
        local rest=""
        local old_ifs="$IFS"

        set -f  # no glob: $input/$opts tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            inseq=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:inseq=${target}"
                    else
                        token="--lua-desync=circular:inseq=${target}"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        IFS="$old_ifs"
        printf '%s' "$out"
    }

    # Окно счётчика на пулах видео — см. обоснование у ensure_circular_time.
    youtube_tcp=$(ensure_circular_time "$youtube_tcp" "$Z2K_CIRCULAR_TIME_SLOW")
    youtube_gv_tcp=$(ensure_circular_time "$youtube_gv_tcp" "$Z2K_CIRCULAR_TIME_SLOW")
    youtube_tcp=$(ensure_circular_tcp_inseq "$youtube_tcp" 18000)
    youtube_gv_tcp=$(ensure_circular_tcp_inseq "$youtube_gv_tcp" 24000)
    # rkn_tcp inseq=26000 (Phase 1.2) — покрывает верхнюю границу TLS-stall'а
    # 14-25 KB по треду ntc.party 22516 #1, #3. yt остаётся на 18000 (типичный
    # first-burst меньше). gv=24000 (выше) и game=4000 (ниже) изменены под их
    # режимы отказа — ревью w8b0e0mex; рационал в комментах у этих строк.
    rkn_tcp=$(ensure_circular_tcp_inseq "$rkn_tcp" 26000)
    # game_tls inseq lowered 18000 → 4000 (Mark approved 2026-05-30): game
    # login/auth/control TLS flows are typically << 18KB, so success seq never
    # crossed 18000 and z2k_success_no_reset never latched. 4000 (< in-range
    # -s5556) is reachable on short flows; the silent CH-drop failure mode is
    # caught by the silent_drop head's out>>in heuristic (zero incoming).

    # ensure_circular_in_range: окно входящих обязано быть ВЫШЕ порога inseq.
    #
    # ЗАЧЕМ. Порог inseq задаётся здесь, а окно `--in-range` живёт в файле
    # стратегий — два разных места, и никто их не сверял. Замерено 2026-08-14:
    #
    #   rkn_tcp  окно -s20000  порог 26000  -> полоса (26000, 20000] пуста
    #   yt_tcp   окно -s5556   порог 18000  -> полоса (18000, 5556]  пуста
    #
    # Успех по входящим срабатывает строго при `начальный rseq > inseq`, а за
    # верхней границей окна nfqws2 выключает Lua по потоку (lua cutoff). Полоса
    # пуста -> путь мёртв, и порог, посаженный за верхнюю границу TLS-затыка
    # (ntc.party 22516: тихий обрыв стрима на 14-30 KB без RST/FIN/alert),
    # не срабатывает ни разу. Ровно от этого уходили 21.05, когда подняли
    # `bytes_in_handshake_done` 3072 -> 16384: голый ServerHello ложно
    # закрепляет страту, которая проходит TLS и ломает потоки HTTP/2 внутри
    # мультиплекса.
    #
    # Инвариант держим ЗДЕСЬ, а не правкой файла стратегий: порог тоже ставится
    # здесь, и только так они больше не разъедутся. Правленный руками
    # Strategy.txt лечится этим же проходом.
    #
    # Запас 1500 байт (у bol-van 1460 = максимум данных в TCP-пакете): нужно,
    # чтобы в полосу успел попасть реальный пакет, а не только её граница.
    # Стоимость невелика: iptables и так отдаёт в очередь первые 30 входящих
    # пакетов потока, так что лишних переходов через ядро нет — прибавляются
    # только вызовы Lua.
    ensure_circular_in_range() {
        local input="$1"
        local inseq="" want="" cur="" out="" token=""

        set -f
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        *:inseq=*) inseq="${token##*:inseq=}"; inseq="${inseq%%:*}" ;;
                    esac
                    ;;
            esac
        done
        case "$inseq" in ''|*[!0-9]*) set +f; printf '%s' "$input"; return 0 ;; esac
        want=$((inseq + 1500))

        for token in $input; do
            case "$token" in
                --in-range=-s*)
                    cur="${token#--in-range=-s}"
                    case "$cur" in
                        ''|*[!0-9]*) ;;
                        *) [ "$cur" -le "$inseq" ] && token="--in-range=-s${want}" ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    # Соединения без SNI движок помечает l7proto=unknown. Профиль с
    # --filter-l7=tls их не берёт — и они уходят в no_action мимо обхода.
    # Ровно так пропадал телевизор: адрес известен через ipcache, а протокол
    # для фильтра «не тот». Пулы видео обязаны брать и unknown. РКН намеренно
    # не трогаем — там на тех же портах живёт слишком много чужого.
    # Токен переписываем перебором, а не регуляркой.
    #
    # Было: sed 's/--filter-l7=tls\([^,a-z_]\|$\)/.../g'. У GNU sed \| это
    # альтернатива, у BSD — литерал, поэтому на макбуке подстановка МОЛЧА не
    # выполнялась. Локальные тесты были зелёными, а в CI на Linux — красными,
    # и разошлось это только на релизе r-77.1. Перебор токенов ведёт себя
    # одинаково везде и заодно точнее: правим ровно тот токен, а не подстроку.
    ensure_l7_unknown() {
        local _t _out=""
        set -f
        for _t in $1; do
            [ "$_t" = "--filter-l7=tls" ] && _t="--filter-l7=tls,unknown"
            _out="${_out:+$_out }$_t"
        done
        set +f
        printf '%s' "$_out"
    }
    youtube_tcp=$(ensure_l7_unknown "$youtube_tcp")
    youtube_gv_tcp=$(ensure_l7_unknown "$youtube_gv_tcp")

    # Инвариант для UDP: пороги детекторов обязаны лежать НИЖЕ окна перехвата.
    #
    # Для TCP такая сверка есть с самого начала (ensure_circular_in_range ниже
    # держит --in-range выше inseq). На UDP её не распространили, и это стоило
    # нам двух месяцев ротации по шуму: udp_in=8 при окне в 3 входящих пакета
    # означает, что успех недостижим, счётчик неудач нечем сбросить, и страта
    # уезжает на полностью здоровом трафике.
    #
    # Мануал, «Обслуживание позиций»: «Счетчик не может и не будет считать то,
    # что не перехватывается». Ошибка молчаливая — ни в логе, ни в статусе она
    # никак не видна, поэтому проверяем на этапе генерации.
    check_udp_thresholds() {
        local pool="$1" tok in_thr out_thr
        # no glob: токены приходят в том числе из Strategy.txt и custom-strategy,
        # где законно встречаются *,?,[ ] — без этого сторож молча слепнет на
        # раскрытом по каталогу токене. Так же обёрнуты все прочие циклы разбора
        # в этом файле.
        set -f
        for tok in $2; do
            case "$tok" in
                --lua-desync=circular:*)
                    case "$tok" in *:udp_in=*) in_thr="${tok##*:udp_in=}"; in_thr="${in_thr%%:*}" ;; *) in_thr="" ;; esac
                    case "$tok" in *:udp_out=*) out_thr="${tok##*:udp_out=}"; out_thr="${out_thr%%:*}" ;; *) out_thr="" ;; esac
                    # Успех срабатывает на пакете udp_in+1 — окно должно его застать.
                    if [ -n "$in_thr" ] && [ "$in_thr" -ge "$Z2K_UDP_PKT_IN" ] 2>/dev/null; then
                        echo "WARN: $pool: udp_in=$in_thr не ниже окна NFQWS2_UDP_PKT_IN=$Z2K_UDP_PKT_IN — успех недостижим, ротация пойдёт по шуму" 1>&2
                    fi
                    if [ -n "$out_thr" ] && [ "$out_thr" -gt "$Z2K_UDP_PKT_OUT" ] 2>/dev/null; then
                        echo "WARN: $pool: udp_out=$out_thr выше окна NFQWS2_UDP_PKT_OUT=$Z2K_UDP_PKT_OUT — провал недостижим" 1>&2
                    fi
                    ;;
            esac
        done
        set +f
    }
    check_udp_thresholds yt_quic "$quic_udp"
    check_udp_thresholds discord_udp "$discord_udp"

    youtube_tcp=$(ensure_circular_in_range "$youtube_tcp")
    youtube_gv_tcp=$(ensure_circular_in_range "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_in_range "$rkn_tcp")

    # ensure_circular_retrans: force `retrans=N` on circular tokens (strip any
    # existing retrans=, re-add). Same strip-and-re-add shape as the nld2/inseq
    # passes above.
    ensure_circular_retrans() {
        local input="$1"
        local target="${2:-1}"
        local out=""
        local token=""
        local opts=""
        local part=""
        local rest=""
        local old_ifs="$IFS"

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            retrans=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:retrans=${target}"
                    else
                        token="--lua-desync=circular:retrans=${target}"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        IFS="$old_ifs"
        printf '%s' "$out"
    }

    # ensure_circular_fails: force `fails=N` on circular tokens (strip any existing
    # fails=, re-add at front). Normalizes pools to bol-van's documented default 3.
    ensure_circular_fails() {
        local input="$1"
        local target="${2:-3}"
        local out=""
        local token=""
        local opts=""
        local part=""
        local rest=""
        local old_ifs="$IFS"

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            fails=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:fails=${target}:${rest}"
                    else
                        token="--lua-desync=circular:fails=${target}"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        IFS="$old_ifs"
        printf '%s' "$out"
    }

    # retrans REVERTED 1→2 (2026-06-08, r-52.5). retrans=1 was set so the per-flow
    # PPE de-offload could rotate offload-blinded silent-drop hosts — nfqws2 dedups
    # identical-seq CH retransmits to a single "retransmission 1/2", so retrans=2
    # never fires for that class, only retrans=1 does. BUT retrans=1 ALSO fires on a
    # single TRANSIENT retransmit of a WORKING host → the false rotations on
    # YouTube/Instagram HTTP/2 hosts under load came back. Mark chose fewer false
    # rotations over auto-rotating the silent-drop class (native bypass covers youtube; a
    # manual state.tsv pin covers the rest). The de-offload layer STAYS (it still
    # restores retransmit visibility for the native detectors).
    # 2026-06-08 (r-54.1): retrans REVERTED 3→2. The r-53 bump to 3 (mis-read as
    # bol-van's "documented" value) made the failure counter need 3 retransmits to
    # trip, so circular got STUCK on a non-working strategy for high-churn clients
    # (YouTube on TV rotated past the only working strat and never settled). 2 is the
    # r-52.5 field value. Flip to 1 to re-enable silent-drop auto-rotation.
    # TCP TLS pools only; UDP doesn't use retrans.
    local Z2K_PPE_DEOFFLOAD
    Z2K_PPE_DEOFFLOAD=$(safe_config_read "Z2K_PPE_DEOFFLOAD" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
    if [ "$Z2K_PPE_DEOFFLOAD" != "0" ]; then
        youtube_tcp=$(ensure_circular_retrans "$youtube_tcp" 2)
        youtube_gv_tcp=$(ensure_circular_retrans "$youtube_gv_tcp" 2)
        rkn_tcp=$(ensure_circular_retrans "$rkn_tcp" 2)
    fi

    # ensure_circular_arg_set: append `<arg>=<value>` (or bare `<arg>` flag)
    # to every circular token in $input that doesn't already carry that arg.
    # Generic helper used to wire success_detector= / no_http_redirect /
    # failure_detector= etc. on TLS profiles. Idempotent for both forms:
    # repeated runs of create_official_config don't pile up duplicates.
    ensure_circular_arg_set() {
        local input="$1"
        local arg_name="$2"
        local arg_value="$3"  # may be empty for flag-style args
        local out=""
        local token=""
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        # value-form already present
                        *":${arg_name}="*) ;;
                        # flag-form already present in middle (followed by another arg)
                        *":${arg_name}:"*) ;;
                        # flag-form already present at end of token
                        *":${arg_name}") ;;
                        *)
                            if [ -n "$arg_value" ]; then
                                token="${token}:${arg_name}=${arg_value}"
                            else
                                token="${token}:${arg_name}"
                            fi
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    # --- bol-van doc-alignment (2026-06-08): fails=3 default on game pools ---
    # NOTE (r-54.1): the `reset` arg was REMOVED from every pool here. In the fork
    # (zapret-auto.lua) `reset` does NOT zero the fail counter — it makes nfqws send
    # a RST to the retransmitter on each failure trip. It is NOT a bol-van circular
    # param (the doc uses time= for counter reset). Adding it in r-53 made nfqws
    # actively RST youtube/blocked flows on transient failures → broke bypass.
    # Inline `reset` was also dropped from the yt/gv/rkn/http_rkn circular tokens.
    # fails normalized to bol-van's documented default 3 on the game pools (they
    # were field-tuned to 2; Mark chose strict doc-alignment). http_rkn fails 2→3
    # is set inline at its definition. yt/gv/rkn/quic/discord already carry fails=3.

    # Этап 2 — проводка failure-детекторов (восстановление из архива, источник
    # a12da74~1). Возвращаем кастомные failure_detector= на TLS-пулы; rkn_tcp
    # проводится ниже через ensure_rkn_failure_detector. success_detector=
    # (Этап 3) и no_http_redirect (Этап 4) — отдельными коммитами. inseq
    # (native arg, ensure_circular_tcp_inseq выше) оставлен.
    #
    # z2k_silent_drop_detector — primary chain-head: внутри делегирует
    # mid_stream_stall → http_mid_stream → http_partial(отцеплен) → tls_stalled →
    # tls_alert_fatal. Все TLS-пулы (rkn/yt/gv) на нём — gv тоже (ревью
    # w8b0e0mex: голый tls_alert_fatal пропускал тихий 16КБ-gate drop, к которому
    # googlevideo максимально подвержен). Детекторы определены в
    # files/lua/z2k-detectors.lua (загружены через --lua-init на Этапе 1).
    # yt_quic (UDP): NATIVE standard_success/failure_detector (UNWIRED 2026-06-05).
    # A custom progress-based detector (z2k_quic_success/z2k_quic_stall, kept in
    # z2k-detectors.lua) was trialed but left unwired: in the field it never fired
    # (phone QUIC connections abandon before the stall window) and wiring its
    # failure_detector would REPLACE native UDP rotation — which appears to work.
    # Functions retained for a future re-trial after threshold calibration; see
    # project_quic_rotation_fix.
    # gv_tcp: было z2k_tls_alert_fatal — голый лист без byte-window/stall-пути.
    # Семантическое ревью (workflow w8b0e0mex) показало: googlevideo.com —
    # ИМЕННО тот пул, что максимально подвержен тихому 16КБ-gate mid-stream
    # drop'у (config_official.sh цитирует это сам), а tls_alert_fatal его НЕ
    # видит (нет RST/FIN/alert → false на всех ветках). Переведён на
    # chain-head silent_drop (как rkn/yt) + in-range=-s26000 (ниже) кормит
    # byte-window, inseq=24000 (выше gate, без near-miss false-pin). Mark
    # approved отход от rotation-«не трогаем» 2026-05-30.

    # Этап 3 — success-детекторы (защита от ложного pin на block-page/neutral).
    # z2k_http_success_positive_only пинит страту ТОЛЬКО на подтверждённый
    # positive HTTP/TLS-ответ (не на 4xx/5xx/cross-SLD redirect — те остаются
    # neutral, ротация продолжается). z2k_success_no_reset (yt) — успех без
    # сброса host-fail-счётчиков (TV-клиенты: успех с другого устройства на том
    # же домене не должен маскировать повторные webOS-фейлы).

    # Этап 4 — no_http_redirect (связка с классификатором). Проверено по
    # нативному zapret-auto.lua:182: redirect-trigger standard_failure_detector
    # гейтится на l7payload=="http_reply" + 302/307 + is_dpi_redirect (ЛЮБОЙ
    # cross-SLD → fail, блант). no_http_redirect его выключает; замена — наш
    # z2k_classify_http_reply (через failure-chain tls_alert_fatal →
    # z2k_http_classifier_check), который hard_fail'ит cross-SLD redirect ТОЛЬКО
    # при block-маркере на target-хосте, а легитимные (oauth/shortlink/CDN) →
    # neutral (не false-fail'ит, продолжает ротацию). Оба гейтятся на http_reply,
    # поэтому на TLS-пулах работают только на DPI-ИНЪЕКТИРОВАННЫЙ plaintext
    # redirect (ровно то, что надо ловить). Связка satisfied: классификатор
    # активен на всех 5 пулах через failure-цепочку (Этап 2). ПОРЯДОК ВАЖЕН —
    # no_http_redirect идёт ПОСЛЕ проводки детекторов (без классификатора он бы
    # глушил redirect-детект → залипание).
    # СНЯТО 2026-08-26. Обоснование выше держалось на замене: native-детект
    # редиректа глушим, потому что его работу берёт наш классификатор через
    # цепочку tls_alert_fatal -> z2k_http_classifier_check. Этой цепочки нет —
    # она жила в удалённом z2k-detectors.lua. Больше того, замены не было и
    # раньше: no_http_redirect срезал тот же проход «вписать, потом вырезать»,
    # и в боевом конфиге его не было ни разу — native-детект редиректа всё это
    # время работал.
    #
    # Сейчас редирект покрыт дважды и осознанно: штатный детектор ловит
    # 302/307 на cross-SLD, а наша обёртка отдельно спрашивает классификатор
    # про маркеры блокировки. Глушить первое ради второго нет причины.

    # Phase 6A: auto-inject fool=z2k_dynamic_ttl into every
    # --lua-desync=fake:*  (and fakedsplit/fakeddisorder/hostfakesplit) that
    # doesn't already pin an explicit TTL via ip_ttl=/ip6_ttl=/ip_autottl=/
    # ip6_autottl=/fool=. The z2k_dynamic_ttl fool hook (files/lua/z2k-fooling-ext.lua)
    # clamps the fake packet TTL to real_egress_ttl-1, making fakes look
    # identical to real client packets from a ТСПУ fingerprint standpoint.
    # Explicit TTL setters are respected — the override is opt-out on a
    # per-strategy basis by adding any of the above args to a strategy.
    #
    # Applied only to TCP profiles (rkn_tcp, yt_tcp, gv_tcp). UDP profiles
    # (quic, discord, game) don't use the fake/fakedsplit family the same
    # way and have their own tuning.
    inject_z2k_dynamic_ttl() {
        local input="$1"
        local token=""
        local out=""
        local skip=""
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*)
                    # Check if the token already pins TTL in any form.
                    skip=""
                    case "$token" in
                        *:ip_ttl=*|*:ip6_ttl=*|*:ip_autottl=*|*:ip6_autottl=*|*:fool=*) skip="1" ;;
                    esac
                    if [ -z "$skip" ]; then
                        token="${token}:fool=z2k_dynamic_ttl"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    # Z2K_DYNAMIC_TTL=0 opt-out: на сетапах с принудительным NDM-TTL-fix
    # (`ip ttl-fix` на Keenetic, чаще всего на мобильных операторах с
    # запретом раздачи — телефонная симка + IMEI-маскировка) NDM
    # перебивает TTL всех исходящих на фиксированное значение независимо
    # от того что наш hook поставил. В этой топологии inject избыточен,
    # а в редких случаях мешает downstream примитивам — даём опт-аут.
    local Z2K_DYNAMIC_TTL
    Z2K_DYNAMIC_TTL=$(safe_config_read "Z2K_DYNAMIC_TTL" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
    if [ "$Z2K_DYNAMIC_TTL" != "0" ]; then
        rkn_tcp=$(inject_z2k_dynamic_ttl "$rkn_tcp")
        youtube_tcp=$(inject_z2k_dynamic_ttl "$youtube_tcp")
        youtube_gv_tcp=$(inject_z2k_dynamic_ttl "$youtube_gv_tcp")
    fi

    # Phase 8: auto-inject z2k JA3 fingerprint breakers (grease, alpn,
    # psk, keyshare) into every --lua-desync=fake:... token that already
    # carries a tls_mod= list. We only extend existing tls_mod arguments;
    # strategies without tls_mod are left alone (they are either non-TLS
    # or intentionally avoid any ClientHello munging). Idempotent — if
    # z2k_grease/etc are already present, the token passes through
    # unchanged so repeated runs of create_official_config don't stack
    # duplicates.
    #
    # Depends on the fork nfqws2 build >= v0.9.4.7-z2k-r3 which
    # introduces the z2k_tls_mod.c dispatcher and the z2k_* mode names.
    # If an older upstream binary is running, parsing these tokens will
    # fail at nfqws2 startup.
    # $2 — `1` means also append `padencap` (Phase 1.4 Z2K_PADENCAP=1
    # default 1 = padencap включён всегда). При =0 padencap не добавляется.
    inject_z2k_tls_mods() {
        local input="$1"
        local with_padencap="${2:-0}"
        local token=""
        local out=""
        # r2 (2026-05-03): z2k_alpn / psk / keyshare после dup-skip fix'а
        # silently skipped на современных blob'ах (где соответствующие
        # extensions уже есть). Добавлены 4 редко-присутствующих
        # extensions для real JA3 distortion: earlydata / pha / sct /
        # delegcred. Требуется fork v0.9.5.2-z2k-r2+.
        local extra="z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare,z2k_earlydata,z2k_pha,z2k_sct,z2k_delegcred"
        if [ "$with_padencap" = "1" ]; then
            extra="${extra},padencap"
        fi
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                *:tls_mod=*)
                    case "$token" in
                        *z2k_grease*|*z2k_alpn*|*z2k_psk*|*z2k_keyshare*|*z2k_earlydata*|*z2k_pha*|*z2k_sct*|*z2k_delegcred*)
                            # Already extended once. If padencap requested
                            # but missing on this token, splice it in.
                            if [ "$with_padencap" = "1" ]; then
                                case "$token" in
                                    *padencap*) : ;;
                                    *)
                                        token=$(printf '%s' "$token" | sed 's|:tls_mod=\([^:]*\)|:tls_mod=\1,padencap|')
                                        ;;
                                esac
                            fi
                            ;;
                        *)
                            # Append z2k modes (and optionally padencap) to
                            # the tls_mod list. tls_mod= is comma-separated;
                            # we insert right after the existing value by
                            # rewriting the first `:tls_mod=VALUE` chunk so
                            # the new modes sit adjacent to upstream modes.
                            # Sed is enough because the value cannot
                            # contain a ':' (would terminate the token).
                            token=$(printf '%s' "$token" | sed "s|:tls_mod=\([^:]*\)|:tls_mod=\1,${extra}|")
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    # 2026-05-03: auto-injection z2k_grease/alpn/psk/keyshare/earlydata/
    # pha/sct/delegcred/padencap отключена. Field-проверка показала net
    # negative: на 7+/8 хостов наши TLS-extension'ы либо ломали handshake
    # (r0 — duplicate ALPN/PSK/key_share без skip-check), либо после r2
    # fix давали слабый JA3 distortion который autocircular не выбирал
    # (простой multisplit пробивает чище). На cloudflare.com fix r2 заработал,
    # но это починка бага r0, не реальный wins. Большинство хостов
    # pin'ятся на не-fake strategies (multisplit/hostfakesplit) у которых
    # tls_mod= вообще нет, инъекция к ним не применяется.
    #
    # Функции `inject_z2k_tls_mods` оставлены в файле и tokens z2k_*
    # доступны через --lua-desync=fake:tls_mod=...,z2k_grease,... — если
    # юзер хочет вручную в strats. Auto-инъекция отключена. Включить
    # обратно: вернуть три строки `inject_z2k_tls_mods` ниже.
    #
    # Z2K_PADENCAP / Z2K_INJECT_TLS_MODS флаги остаются для возможного
    # opt-in возврата, но default — НЕ инжектить ничего.
    local Z2K_INJECT_TLS_MODS
    Z2K_INJECT_TLS_MODS=$(safe_config_read "Z2K_INJECT_TLS_MODS" "${ZAPRET2_DIR:-/opt/zapret2}/config" "0")
    if [ "$Z2K_INJECT_TLS_MODS" = "1" ]; then
        local Z2K_PADENCAP
        Z2K_PADENCAP=$(safe_config_read "Z2K_PADENCAP" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
        rkn_tcp=$(inject_z2k_tls_mods "$rkn_tcp" "$Z2K_PADENCAP")
        youtube_tcp=$(inject_z2k_tls_mods "$youtube_tcp")
        youtube_gv_tcp=$(inject_z2k_tls_mods "$youtube_gv_tcp")
    fi

    # Ротация tcp_ts по слотам СНЯТА: значения теперь записаны прямо в пуле
    # (strats_new2.txt, строка манифеста rkn) и приезжают в Strategy.txt как
    # есть. Раньше генератор переписывал `tcp_ts=-1000` по НОМЕРУ стратегии по
    # таблице из четырнадцати слотов — и это была мина: любая вставка или
    # перестановка стратегии в пуле молча уводила чужие значения на чужие
    # стратегии. Ровно так однажды и вышло (случай со strategy=37 и ozon.ru,
    # прикусившим браузер). Плюс к моменту снятия пять слотов таблицы уже
    # указывали в пустоту — в пуле не осталось токенов с такими номерами.
    #
    # Значения не изменились: сгенерированный NFQWS2_OPT до и после снятия
    # совпадает побайтно (tests/test_tcp_ts_baked.sh стережёт, что в пуле нет
    # выгоревшего -1000 на тех слотах и что генератор его больше не трогает).

    # Phase 14: bol-van badseq alias expansion.
    #
    # Upstream bol-van/zapret has `--dpi-desync-fooling=badseq` with
    # integer defaults -10000 for tcp_seq and -66000 for tcp_ack (the
    # -66000 value is specifically chosen to drift past Linux conntrack's
    # window-scaled tolerance introduced in 2.6.18; see GoodbyeDPI
    # fakepackets.c:218 for the reference). The flag, when set, just
    # does `th_seq += increment` and `th_ack += ack_increment` inside
    # fill_tcphdr() on fake/decoy packets only, never on real data.
    #
    # Our zapret2 fork dropped FOOL_BADSEQ from C-side fooling bits
    # (the whole fooling machinery was rewritten to Lua standard-fooling),
    # so tokens like `:badseq:badseq_increment=N:badseq_ack_increment=M:`
    # written in the spirit of bol-van get silently ignored by the Lua
    # argument parser — they're dead noise in 8 of our rkn_tcp strategies
    # and 6 yt/gv variants. The functional equivalent in our code is
    # `tcp_seq=N:tcp_ack=M` inside standard fooling, which does land in
    # apply_fooling() → reconstructed fake packet, matching bol-van's
    # fill_tcphdr() behavior bit-for-bit.
    #
    # This preprocessor transparently rewrites the bol-van syntax into
    # our tcp_seq/tcp_ack syntax:
    #   `:badseq:`                        → `:tcp_seq=-10000:tcp_ack=-66000:`
    #   `:badseq_increment=N:`            → `:tcp_seq=N:tcp_ack=-66000:`
    #   `:badseq_increment=N:badseq_ack_increment=M:` → `:tcp_seq=N:tcp_ack=M:`
    #
    # Existing explicit `tcp_seq=` / `tcp_ack=` on the same token win
    # (we never override an explicit user setting). The badseq tokens
    # themselves are dropped from the output so there's no residual
    # dead syntax in NFQWS2_OPT. Applied to fake-family tokens (fake,
    # fakedsplit, fakeddisorder, hostfakesplit, rst, rstack, syndata,
    # synack) — strictly mirroring bol-van's "fake/decoy only" invariant.
    expand_badseq_aliases() {
        local input="$1"
        local token=""
        local out=""
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*|\
                --lua-desync=rst:*|\
                --lua-desync=rstack:*|\
                --lua-desync=syndata:*|\
                --lua-desync=synack:*)
                    case "$token" in
                        # The literal `:` chars in `*:badseq:*` act as
                        # left+right word boundaries — tokens like
                        # `:fakebadseq:` or `:badseq_extra:` cannot match
                        # (the second `:` would require `badseq` followed
                        # by `:`). The other two patterns target
                        # `:badseq_increment=<N>:` / `:badseq_ack_increment=<N>:`
                        # explicitly, with no ambiguity.
                        *:badseq:*|*:badseq_increment=*|*:badseq_ack_increment=*)
                            token=$(printf '%s' "$token" | awk '
                                BEGIN { FS = ":"; OFS = ":"; DEF_SEQ = -10000; DEF_ACK = -66000 }
                                {
                                    has = 0
                                    seq_set = 0; seq_val = DEF_SEQ
                                    ack_set = 0; ack_val = DEF_ACK
                                    ex_seq = 0; ex_ack = 0
                                    out = ""
                                    for (i = 1; i <= NF; i++) {
                                        p = $i
                                        if (p == "badseq") { has = 1; continue }
                                        if (index(p, "badseq_increment=") == 1) {
                                            has = 1; seq_set = 1
                                            seq_val = substr(p, length("badseq_increment=") + 1)
                                            continue
                                        }
                                        if (index(p, "badseq_ack_increment=") == 1) {
                                            has = 1; ack_set = 1
                                            ack_val = substr(p, length("badseq_ack_increment=") + 1)
                                            continue
                                        }
                                        if (index(p, "tcp_seq=") == 1) ex_seq = 1
                                        if (index(p, "tcp_ack=") == 1) ex_ack = 1
                                        out = (out == "" ? p : out ":" p)
                                    }
                                    if (has) {
                                        if (!ex_seq) out = out ":tcp_seq=" seq_val
                                        if (!ex_ack) out = out ":tcp_ack=" ack_val
                                    }
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    rkn_tcp=$(expand_badseq_aliases "$rkn_tcp")
    youtube_tcp=$(expand_badseq_aliases "$youtube_tcp")
    youtube_gv_tcp=$(expand_badseq_aliases "$youtube_gv_tcp")

    # Phase 14b: strip dead :out_range=*: / :in_range=*: tokens from
    # inside --lua-desync=... args.
    #
    # These live as CLI-level in-profile filters (--out-range / --in-range
    # per docs/manual.en.md:696, nfqws.c:2147-2148), NOT as per-strategy
    # Lua args. When someone writes `:out_range=-n2:` inside a lua-desync
    # token (a common mistake copied from bol-van syntax where
    # --dpi-desync-cutoff=n2 lives on the command line), the Lua arg
    # parser happily stores it in desync.arg.out_range and no Lua
    # function ever reads it — silent no-op. blockcheck-generated
    # Strategy.txt files from older z2k versions are full of these
    # tokens, and they clutter the generated NFQWS2_OPT without
    # doing anything. This preprocessor scrubs them.
    #
    # Applied to every strategy string that might have been hand-edited
    # or imported from older Strategy.txt blockcheck output.
    strip_dead_range_args() {
        local input="$1"
        local token=""
        local out=""
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=*)
                    case "$token" in
                        *:out_range=*|*:in_range=*)
                            token=$(printf '%s' "$token" | awk '
                                BEGIN { FS = ":"; OFS = ":" }
                                {
                                    out = ""
                                    for (i = 1; i <= NF; i++) {
                                        p = $i
                                        if (index(p, "out_range=") == 1) continue
                                        if (index(p, "in_range=") == 1) continue
                                        out = (out == "" ? p : out ":" p)
                                    }
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    rkn_tcp=$(strip_dead_range_args "$rkn_tcp")
    youtube_tcp=$(strip_dead_range_args "$youtube_tcp")
    youtube_gv_tcp=$(strip_dead_range_args "$youtube_gv_tcp")
    quic_udp=$(strip_dead_range_args "$quic_udp")

    # z2k_dynamic_strategy slot removed in r-15 Phase 1 (
    # detection stack cleanup). The slot existed only to be filled by
    # the z2k-classify generator, which produced the
    # /opt/zapret2/lists/z2k-classify-*.tsv DBs and
    # /tmp/z2k-classify-dynparams transient params. classify is gone,
    # producer DBs are not written by anyone, and the handler quietly
    # no-op'd every flow. Phase 3 (z2k-detect daemon) feeds back
    # through discovered-domains.txt / whitelist.txt — a different
    # per-domain mechanism, not a per-flow dynamic-params one.

    discord_udp=$(strip_dead_range_args "$discord_udp")

    # Phase 3 helper: rebase every `:strategy=N` inside a strategy string
    # by a fixed offset. Used to shift GV strategies (1..22) to (23..44)
    # so they don't collide with youtube_tcp's 1..22 when the two
    # profiles are merged into google_tls. Not applied unconditionally —
    # only invoked inside the Phase 3 emit guard.
    rebase_strategy_ids() {
        local input="$1"
        local offset="$2"
        # Consume $0 by moving past each rewritten `:strategy=N` — naïve
        # `while match` loops forever because the new (N+off) value is
        # itself a :strategy=[0-9]+ match at the same position.
        printf '%s' "$input" | awk -v off="$offset" '
            {
                result = ""
                # Match :strategy=<int> with optional leading whitespace
                # and optional sign so future Strategy.txt formats
                # (negative IDs, indented keys) survive a rebase.
                while (match($0, /:strategy=[[:space:]]*-?[0-9]+/)) {
                    result = result substr($0, 1, RSTART - 1)
                    raw = substr($0, RSTART + 10, RLENGTH - 10)
                    gsub(/[[:space:]]/, "", raw)
                    sid = (raw + 0) + off
                    result = result ":strategy=" sid
                    $0 = substr($0, RSTART + RLENGTH)
                }
                result = result $0
                print result
            }'
    }

    # Phase 7: convert fixed `repeats=N` on fake-family actions to the
    # range syntax `repeats=max(1,N-2)-(N+2)`. The z2k-range-rand.lua
    # wrapper picks a sticky random integer per flow from this range,
    # breaking per-flow DPI fingerprints that hash on fake-packet count.
    # Midpoint matches the original value, so average behaviour is
    # unchanged and there's no performance hit.
    #
    # Idempotency: awk регексп `^repeats=[0-9]+$` строго точечный —
    # part'ы вида `repeats=N-M` (уже диапазон) не матчатся, проходят
    # через awk без изменений. Этот же регексп служит фильтром на
    # пользовательские хитрости вроде `repeats=4-8` — мы их не трогаем.
    #
    # 2026-05-01 fix: убран outer glob `case "$token" in *:repeats=*-*) : ;;`
    # — он давал false-positive на любом токене где после `:repeats=N`
    # встречался `-` (например `tcp_ts=-1000`, `tcp_seq=-66000`,
    # `ip_autottl=-2,3-20`). Из-за этого 39 fake-токенов с tcp_ts
    # никогда не получали randomization — TSPU видела предсказуемый
    # repeat count для fingerprint'а. awk внутри сам корректно
    # идемпотентен на per-part уровне, outer глоб был избыточен и багован.
    inject_z2k_range_rand() {
        local input="$1"
        local token=""
        local out=""
        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*|\
                --lua-desync=syndata:*)
                    case "$token" in
                        *:repeats=*)
                            token=$(printf '%s' "$token" | awk '
                                {
                                    n = split($0, parts, ":")
                                    for (i = 1; i <= n; i++) {
                                        if (parts[i] ~ /^repeats=[0-9]+$/) {
                                            v = substr(parts[i], 9) + 0
                                            lo = (v - 2 < 1) ? 1 : v - 2
                                            hi = v + 2
                                            parts[i] = "repeats=" lo "-" hi
                                        }
                                    }
                                    out = parts[1]
                                    for (i = 2; i <= n; i++) out = out ":" parts[i]
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        set +f
        printf '%s' "$out"
    }

    rkn_tcp=$(inject_z2k_range_rand "$rkn_tcp")
    youtube_tcp=$(inject_z2k_range_rand "$youtube_tcp")
    youtube_gv_tcp=$(inject_z2k_range_rand "$youtube_gv_tcp")

    # NOTE: rkn_tcp default failure_detector is z2k_tls_stalled
    # (set in ensure_rkn_failure_detector() below, applied AFTER injectors
    # run). См. там же подробности про revert mid_stream_stall → tls_stalled
    # 2026-04-30 после code-review.

    # Let YouTube TLS circular operate exactly as in the upstream manual.
    # For LG webOS the orchestrator must see incoming packets on the circular
    # stage itself (`--in-range=-sN`), while actual desync instances must
    # still stay limited by `--payload=tls_client_hello...`.
    #
    # This requires moving the top-level `--payload=` after circular and
    # closing the incoming window right after circular with `--in-range=x`.
    # Keeping payload before circular makes YouTube TCP/GV fail detection too
    # blind and prevents real sequential rotation on TV clients.
    #
    # $2 is the byte cap for the inserted `--in-range=-sN`; default 5556
    # matches the master-compatible layout. rkn_tcp passes 20000 when the
    # mid-stream-detector bundle flag is on, so its lua failure_detector
    # can observe the [8K, 18K] CF stall window.
    ensure_youtube_tls_circular_manual_layout() {
        local input="$1"
        local in_range_bytes="${2:-5556}"
        local token=""
        local has_tls="0"
        local has_circular="0"
        local has_in_range=""
        local before_circular=""
        local circular_token=""
        local after_circular=""
        local saved_payload=""
        local phase="before"

        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$token" in
                # tls ИЛИ tls с довесками: пул видео ходит с
                # --filter-l7=tls,unknown, чтобы забирать соединения без SNI.
                # Жёсткое сравнение здесь означало, что раскладка с --in-range
                # молча не применялась и окно наблюдения оставалось пустым.
                --filter-l7=tls|--filter-l7=tls,*) has_tls="1" ;;
                --lua-desync=circular:*) has_circular="1" ;;
                --in-range=*) has_in_range="1" ;;
            esac
        done
        set +f

        if [ "$has_tls" != "1" ] || [ "$has_circular" != "1" ]; then
            printf '%s' "$input"
            return 0
        fi

        # If a profile already has an explicit in-range, leave it alone.
        [ -n "$has_in_range" ] && {
            printf '%s' "$input"
            return 0
        }

        set -f  # no glob: $input tokens may contain *,?,[ ] from hand-edited Strategy.txt
        for token in $input; do
            case "$phase" in
                before)
                    case "$token" in
                        --payload=*)
                            saved_payload="$token"
                            ;;
                        --lua-desync=circular:*)
                            circular_token="$token"
                            phase="after"
                            ;;
                        *)
                            before_circular="${before_circular:+$before_circular }$token"
                            ;;
                    esac
                    ;;
                after)
                    after_circular="${after_circular:+$after_circular }$token"
                    ;;
            esac
        done
        set +f

        [ -z "$circular_token" ] && {
            printf '%s' "$input"
            return 0
        }

        # Fallback for malformed legacy inputs with no payload token.
        [ -z "$saved_payload" ] && saved_payload="--payload=tls_client_hello"

        printf '%s --in-range=-s%s %s --in-range=x %s%s%s' \
            "$before_circular" \
            "$in_range_bytes" \
            "$circular_token" \
            "$saved_payload" \
            "${after_circular:+ }" \
            "$after_circular"
    }

    # YouTube TCP on LG webOS often fails as a silent TCP blackhole:
    # repeated ClientHello attempts with no visible response_state/success_state.
    # Manual payload reordering alone is not sufficient in that mode.
    #
    # Conservative TCP failure path:
    # - expose incoming packets to circular via --in-range=-sN
    # - expose empty packets / retrans context via --payload=tls_client_hello,empty
    # - keep desync strategy instances restricted to the original TLS payload
    # - prevent successes from other devices on the same domain from resetting
    #   failure counters via success_detector=z2k_success_no_reset
    #
    # Используется только youtube_tcp. Тумблер RKN_SILENT_FALLBACK, водивший
    # сюда же rkn_tcp, снят 2026-08-17: замер генератора показал, что вся его
    # разница — добавленный `--payload=tls_client_hello,empty` перед circular,
    # тогда как в дефолтном пути payload переносится ЗА circular и тот идёт с
    # `--payload=all` (дефолт движка). all ⊃ {tls_client_hello, empty}, то есть
    # тумблер обзор не расширял, а сужал. Детектор z2k_silent_drop_detector,
    # ради которого он назывался silent, в конфиг не попадал ни при ON, ни при
    # OFF: его срезал проход, включённый по умолчанию. С 2026-08-26 нет ни
    # детектора, ни прохода — файл z2k-detectors.lua удалён как недостижимый.
    #
    # $2 is the byte cap for the inserted `--in-range=-sN`; default 5556
    # matches the master-compatible layout that youtube_tcp keeps.
    ensure_youtube_tls_failure_detection() {
        local input="$1"
        local in_range_bytes="${2:-5556}"
        local token=""
        local has_tls="0"
        local has_circular="0"
        local has_in_range=""
        local saved_payload=""
        local out=""
        local circular_seen="0"

        for token in $input; do
            case "$token" in
                # tls ИЛИ tls с довесками: пул видео ходит с
                # --filter-l7=tls,unknown, чтобы забирать соединения без SNI.
                # Жёсткое сравнение здесь означало, что раскладка с --in-range
                # молча не применялась и окно наблюдения оставалось пустым.
                --filter-l7=tls|--filter-l7=tls,*) has_tls="1" ;;
                --lua-desync=circular:*) has_circular="1" ;;
                --in-range=*) has_in_range="1" ;;
            esac
        done

        if [ "$has_tls" != "1" ] || [ "$has_circular" != "1" ]; then
            printf '%s' "$input"
            return 0
        fi

        # If a profile already has an explicit in-range, leave it alone.
        [ -n "$has_in_range" ] && {
            printf '%s' "$input"
            return 0
        }

        [ -z "$saved_payload" ] && saved_payload="--payload=tls_client_hello"

        for token in $input; do
            case "$token" in
                --payload=*)
                    saved_payload="$token"
                    token=$(printf '%s' "$token" | sed 's/^--payload=tls_client_hello$/--payload=tls_client_hello,empty/')
                    ;;
                --lua-desync=circular:*)
                    out="${out:+$out }--in-range=-s${in_range_bytes}"
                    # native rollback 2026-05-28: НЕ инжектим success_detector=z2k_*
                    # — нативный circular использует standard_success_detector по
                    # умолчанию. Layout (in-range/payload-gate) сохраняется.
                    circular_seen="1"
                    ;;
            esac

            if [ "$circular_seen" = "1" ]; then
                case "$token" in
                    --lua-desync=circular:*) ;;
                    --lua-desync=*)
                        out="${out:+$out }--in-range=x $saved_payload"
                        circular_seen="2"
                        ;;
                esac
            fi

            out="${out:+$out }$token"
        done

        printf '%s' "$out"
    }

    # yt_tcp переведён на ту же раскладку, что gv_tcp и rkn_tcp (19.08.2026).
    #
    # ensure_youtube_tls_failure_detection оставляет --payload= ПЕРЕД circular,
    # и инстанс получает payload_type = {tls_client_hello, empty} вместо all.
    # Ровно об этом сужении написано в комментарии выше — вывод сделали, когда
    # снимали тумблер RKN_SILENT_FALLBACK, но сам yt_tcp на сужающей ветке так
    # и остался. Цена, замер на боевом роутере 19.08.2026:
    #   key="yt_tcp" ... payload_type= empty tls_client_hello
    #   key="gv_tcp" ... payload_type= all
    #   key="rkn_tcp" ... payload_type= all
    # Движок зовёт инстанс только на подходящем payload, поэтому на yt_tcp до
    # детектора НЕ доходил ни один входящий пакет С ДАННЫМИ. Мёртвыми там были
    # разом: правило вставшего потока (при том что yt_tcp прямо перечислен в
    # Z2K_RETRANS_POOLS), фатальный TLS-алерт, сверка TTL и весь гвард живости —
    # им всем нужен пакет с пейлоадом. Доезжали только исходящий ClientHello и
    # пустые пакеты, то есть RST без единого гварда.
    youtube_tcp=$(ensure_youtube_tls_circular_manual_layout "$youtube_tcp" "19500")
    youtube_gv_tcp=$(ensure_youtube_tls_circular_manual_layout "$youtube_gv_tcp" "26000")

    # RKN: failure_detector — z2k_tls_stalled by default, overridable
    # to z2k_mid_stream_stall through Z2K_USE_MID_STREAM_DETECTOR=1.
    #
    # 2026-04-30 the default was reverted from mid_stream_stall to
    # tls_stalled because the original mid_stream_stall implementation
    # had four architectural problems that combined into a worse-than-
    # nothing detector — see commit fdc7145 for the full diagnosis.
    # 14984c3 (2026-05-01) landed a v3 redesign of z2k_mid_stream_stall:
    # per-flow byte tracking via desync.track.lua_state, multi-
    # candidate map per nld=2 key, FIN/RST closure handling, active-
    # retry gate via ch_gap. Tests in tests/test_mid_stream_stall.lua
    # codify the contract.
    #
    # Этап 2 (2026-05-30): ensure_rkn_failure_detector ВНОВЬ функционален —
    # инжектит :failure_detector=z2k_silent_drop_detector на rkn_tcp circular
    # (chain-head делегирует к mid_stream_stall/tls_stalled/tls_alert). Это
    # отменяет native-rollback от 2026-05-28; кастомные детекторы вернулись из
    # archive/custom-detectors-rotation/ и загружены через --lua-init (Этап 1).
    #
    # Флаг Z2K_USE_MID_STREAM_DETECTOR (default 1) теперь управляет ТОЛЬКО
    # --in-range byte-cap rkn (-s5556 → -s20000) — расширяет окно, которое
    # видит chain-head, чтобы byte-window mid_stream_stall дотягивался до
    # 16КБ-gate. Сам выбор детектора флагом НЕ переключается (всегда silent_drop).
    ensure_rkn_failure_detector() {
        local input="$1"
        # Имя детектора обязательно. Значения по умолчанию здесь больше нет:
        # оно указывало на функцию из удалённого z2k-detectors.lua, и молчаливое
        # применение такого умолчания довело бы до движка несуществующее имя —
        # error() на каждом пакете и профиль-пустышка при зелёной службе.
        local detector_name="${2:?ensure_rkn_failure_detector: имя детектора обязательно}"
        local out=""
        local token=""
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        *failure_detector=*) ;;
                        *) token="${token}:failure_detector=${detector_name}" ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    # Z2K_USE_MID_STREAM_DETECTOR=1 расширяет --in-range byte cap rkn_tcp
    # (s5556 → s20000), чтобы chain-head z2k_silent_drop_detector видел
    # 16КБ-gate-окно. Сам failure_detector ниже — z2k_silent_drop_detector
    # (chain делегирует к mid_stream/tls_stalled/tls_alert). Флаг управляет
    # ТОЛЬКО byte-cap, не выбором детектора.
    local rkn_in_range_bytes="5556"
    if [ "$Z2K_USE_MID_STREAM_DETECTOR" = "1" ]; then
        rkn_in_range_bytes="20000"
    fi

    # ---- Pure bol-van standard detectors (DEFAULT) --------------------------
    # Strips ALL custom failure/success detector wiring (z2k_silent_drop_detector
    # / z2k_http_success_positive_only / z2k_success_no_reset) + the
    # no_http_redirect override from every TCP circular pool, falling back to
    # bol-van's standard_failure_detector / standard_success_detector. Rationale
    # (verified vs zapret-auto.lua:213/241): standard already catches BOTH block
    # classes with NO outgoing-packet-count heuristic, so it cannot false-rotate
    # working HTTP/2 hosts (the r-49 class):
    #   - incoming RST  (seq<=inseq) — visible after the connmark-reply fix;
    #   - silent drop   (outgoing retrans>=3 default) — client's own retransmits,
    #                     always visible via the unbroken POSTROUTING rule;
    #   - DPI redirect  (302/307 -> is_dpi_redirect).
    # NON-detector args (inseq=, reset, in-range, payload) are KEPT — those are
    # native circular tuning, not custom detectors.
    #
    # Ротация в движке с 18.08.2026 всегда нативная: переключателя режима
    # больше нет, ветка r-49 снята с вооружения вместе с ним.
    # См. [project_pure_default_rotation].
    # СНЯТО 2026-08-26 вместе с удалением z2k-detectors.lua.
    #
    # Здесь стоял проход, вырезавший из профилей ЛЮБОЙ :failure_detector= и
    # :success_detector=, и включён он был по умолчанию. То есть выше по файлу
    # детекторы вписывались, а здесь тут же вырезались — в конфиг они не
    # попадали ни разу. Замер боевого конфига 26.08 это подтвердил: ни одного
    # success_detector=, из failure_detector= только наша обёртка.
    #
    # Вместе с проходом снят и флаг Z2K_NATIVE_DETECTORS: его нулевое значение
    # доводило до движка имена функций, которых больше нет на диске, а движок
    # на неизвестном имени детектора валится в error() НА КАЖДОМ ПАКЕТЕ
    # профиля. Это не «детектор не работает» — это профиль становится
    # пустышкой при зелёном статусе службы.

    # ---- Поправки к штатному детектору (files/lua/z2k-alert.lua) -------------
    #
    # Прохода-резака, вырезавшего ЛЮБОЙ :failure_detector=, здесь больше нет
    # (снят 2026-08-26). Порядок всё равно значим: проводка обязана идти после
    # всех правок профилей, иначе очередной проход её затрёт — именно так наша
    # обёртка однажды и исчезала из конфига молча.
    #
    # Сам детектор не заменяет штатный, а оборачивает: вызывает
    # standard_failure_detector и добавляет ровно два отличия, оба измерены на
    # боевом роутере 2026-08-18 (подробности — в шапке lua-файла):
    #   1. ретрансмиссию считаем провалом только на ClientHello. Иначе провалом
    #      становится любая потеря пакета в уже работающей сессии, и рабочая
    #      страта уезжает при 29 успехах против 3 провалов;
    #   2. фатальный TLS-алерт до ServerHello считаем провалом. Без этого целый
    #      класс блокировок (сервер подтверждает ClientHello, отвечает алертом и
    #      закрывается по FIN) не даёт детектору вообще никакого события, и
    #      нерабочая страта не ротируется никогда.
    #
    # Изначально ставилось только на rkn_tcp. С 2026-08-18 стоит и на пулах
    # видео: замер по ним получен, см. ниже у самой проводки.
    #
    # Проводка ставится ТОЛЬКО если файл детектора реально лежит на диске.
    # Без него движок валится в error() на каждом пакете профиля, а это не
    # «детектор не работает», это «профиль РКН стал пустышкой» — при зелёном
    # статусе сервиса и без единой жалобы в логе.
    if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/lua/z2k-alert.lua" ]; then
        rkn_tcp=$(ensure_rkn_failure_detector "$rkn_tcp" "z2k_fail_tls_alert")
        # Пулы видео — замер 2026-08-18 на LG webOS. На заведомо нерабочей
        # стратегии соединение поднималось, сервер отдавал 4482 байта и дальше
        # слал один и тот же сегмент 15-16 раз. Ни RST, ни FIN, ни исходящих
        # ретрансмитов — штатный детектор молчал (676 вызовов, ноль событий),
        # страта стояла вечно, видео и превью не грузились.
        # С обёрткой: ytimg 20->22, googleusercontent 20->21, ggpht 20->21,
        # googlevideo 20->21, одиннадцать ротаций, всё на живом трафике.
        youtube_tcp=$(ensure_rkn_failure_detector "$youtube_tcp" "z2k_fail_tls_alert")
        youtube_gv_tcp=$(ensure_rkn_failure_detector "$youtube_gv_tcp" "z2k_fail_tls_alert")
    else
        echo "WARN: lua/z2k-alert.lua отсутствует — детекторы остаются чисто штатными" 1>&2
    fi

    # QUIC — детектор по молчанию, отдельным файлом и отдельным гейтом.
    #
    # Штатный детектор для QUIC не работает в принципе: он считает провалом
    # «отослано много, принято мало», а мёртвый QUIC-поток шлёт МЕНЬШЕ пакетов,
    # чем живой — браузер не ретрансмитит Initial, а уходит на TCP. Замер
    # 2026-08-19 по 1646 потокам: ни один порог от 2 до 12 эти классы не
    # разделяет. Различает их время, поэтому детектор ждёт ответа по таймеру.
    if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/lua/z2k-quic-silence.lua" ]; then
        quic_udp=$(ensure_rkn_failure_detector "$quic_udp" "z2k_fail_quic_silence")
    else
        echo "WARN: lua/z2k-quic-silence.lua отсутствует — QUIC остаётся на штатном детекторе" 1>&2
    fi

    rkn_tcp=$(ensure_youtube_tls_circular_manual_layout "$rkn_tcp" "$rkn_in_range_bytes")

    # Окно входящих обязано быть выше порога inseq — второй проход.
    #
    # Инвариант заведён выше (ensure_circular_in_range, вызовы у объявления
    # порогов). Тот проход правит только УЖЕ существующий в стратегии токен
    # `--in-range=-sN`, а в дефолтной поставке его там нет вовсе: окно
    # вставляют раскладчики (ensure_youtube_tls_*) ниже по коду, и вставляют
    # константу, ничего не зная про inseq. Гейт оказывался позади события,
    # которое сторожит.
    #
    # Замерено на боевом роутере 2026-08-17 (конфиг сгенерирован кодом, где
    # первый проход уже был):
    #   rkn_tcp  --in-range=-s20000  inseq=26000  -> полоса пуста
    #   yt_tcp   --in-range=-s5556   inseq=18000  -> полоса пуста
    #   gv_tcp   --in-range=-s26000  inseq=24000  -> ок (константа совпала)
    #
    # Прогон после раскладчиков чинит все три разом и держит единственный
    # источник правды — сам ensure_circular_in_range с его запасом 1500.
    youtube_tcp=$(ensure_circular_in_range "$youtube_tcp")
    youtube_gv_tcp=$(ensure_circular_in_range "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_in_range "$rkn_tcp")

    # Генерировать NFQWS2_OPT в формате официального config
    local nfqws2_opt_lines=""

    # Helper: проверить наличие и непустоту hostlist-файлов
    add_hostlist_line() {
        local list_path="$1"
        shift
        if [ -s "$list_path" ]; then
            nfqws2_opt_lines="$nfqws2_opt_lines$*\\n"
        else
            echo "WARN: hostlist file missing or empty: $list_path (skip profile)" 1>&2
            print_warning "Hostlist missing or empty: $list_path — profile skipped"
        fi
    }


    # Общее для профилей объявляем ОДИН раз.
    #
    # Исключения по whitelist повторялись восемью литералами в восьми строках,
    # а РКН-триада хостлистов собиралась двумя независимыми блоками кода — и
    # они уже разъехались: TCP_Discord.txt попал только в один из них. Любое
    # изменение общего условия требовало правки во всех местах сразу, и
    # промах был бы виден не в тестах, а у людей.
    local wl_excl="--hostlist-exclude=${lists_dir}/whitelist.txt"

    # --------------------------------------------------------------------------
    # ШАБЛОН ДВИЖКА: арсенал РКН объявляется один раз
    # --------------------------------------------------------------------------
    #
    # Профиль cf_extra — это ДОСЛОВНАЯ копия арсенала rkn_tcp, отличающаяся
    # ровно одним словом (key= у circular). Замерено на боевых пулах: 13 154
    # байта совпадают побайтно, а весь профиль — 30% всей строки NFQWS2_OPT.
    # Копия делалась `sed s/key=rkn_tcp/key=cf_extra/` по готовой строке, то
    # есть любая правка арсенала уезжала в оба места молча — и длина
    # командной строки платилась дважды. Длина здесь не абстракция: разбор
    # 29 КБ строки шеллом уже стоил 17 из 25 секунд рестарта.
    #
    # Движок умеет объявить набор один раз (--template=имя) и подставить его в
    # профиль (--import=имя). Правила слияния (проверены прогоном движка):
    #   • инстансы шаблона ДОПИСЫВАЮТСЯ в хвост списка профиля — поэтому
    #     circular обязан быть объявлен ДО --import, иначе оркестратор не
    #     увидит ни одной своей стратегии (план строится только из инстансов,
    #     идущих ПОСЛЕ него) и упадёт;
    #   • --payload/--in-range/--out-range — это состояние разборщика, оно
    #     снимается в момент объявления инстанса и переезжает вместе с ним;
    #     поэтому в шаблон переносится и состояние из головы профиля;
    #   • шаблон обязан быть объявлен РАНЬШЕ первого --import: ссылка вперёд
    #     не работает, движок падает с «template not found».
    #
    # Аварийный выключатель: Z2K_NFQWS2_TEMPLATES=0 возвращает прежнюю плоскую
    # сборку. Пробу бинарника не делаем: --template/--import есть во всех
    # сборках движка, которые z2k когда-либо ставил (проверено strings по
    # релизным бинарникам и по тегам форка), а лишний запуск движка на каждую
    # генерацию конфига — это ещё один fork+exec на каждый щелчок тумблера.
    local z2k_templates rkn_tpl rkn_head rkn_circ rkn_tail rkn_tpl_line=""
    z2k_templates=$(safe_config_read "Z2K_NFQWS2_TEMPLATES" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
    rkn_tpl="z2k_rkn_arsenal"
    rkn_head=""; rkn_circ=""; rkn_tail=""
    if [ "$z2k_templates" != "0" ] && [ -n "$rkn_tcp" ]; then
        local _t _state=""
        for _t in $rkn_tcp; do
            case "$_t" in
                --lua-desync=circular:*)
                    if [ -z "$rkn_circ" ]; then rkn_circ="$_t"; continue; fi
                    ;;
            esac
            if [ -z "$rkn_circ" ]; then
                rkn_head="${rkn_head:+$rkn_head }$_t"
                # Состояние разборщика из головы действует и на инстансы,
                # уезжающие в шаблон. Не перенести его — значит отдать им
                # дефолтные диапазоны вместо -s34228.
                case "$_t" in
                    --payload=*|--in-range=*|--out-range=*) _state="${_state:+$_state }$_t" ;;
                esac
            else
                rkn_tail="${rkn_tail:+$rkn_tail }$_t"
            fi
        done
        if [ -n "$rkn_circ" ] && [ -n "$rkn_tail" ]; then
            rkn_tpl_line="--template=$rkn_tpl${_state:+ $_state} $rkn_tail --new"
        else
            # Пул без circular (или без стратегий после него) шаблоном не
            # выражается — собираем как раньше.
            rkn_head=""; rkn_circ=""; rkn_tail=""
        fi
    fi

    # Хостлисты РКН-домена собираются ОДИН раз на два профиля — TLS (443) и
    # HTTP (80). Раньше их собирали два независимых блока кода, и они уже
    # разошлись: Discord-список попал только в первый. Теперь расхождение
    # выражено явно — общая часть в одной переменной, отличие ровно одно и
    # прокомментировано.
    local rkn_lists_head="--hostlist=${extra_strats_dir}/TCP/RKN/List.txt"
    local rkn_lists_tail=""
    # Shipped extras curated on top of runetfreedom RKN — domains users
    # reported missing (fast-torrent.ru etc). Refreshed on every install.
    [ -s "${lists_dir}/extra-domains.txt" ] && rkn_lists_tail="$rkn_lists_tail --hostlist=${lists_dir}/extra-domains.txt"
    # z2k-detect daemon-managed hostlist. Populated reactively from probe
    # verdicts (hot ∪ cache → discovered-domains.txt). Wired unconditionally
    # — install.sh touches the file early (step_build_zapret2) so the path
    # is always valid by the time NFQWS2_OPT is generated. Dropping the
    # `[ -e ]` guard makes the wiring static against static analysis and
    # eliminates a "fresh install timing" foot-gun.
    rkn_lists_tail="$rkn_lists_tail --hostlist=${lists_dir}/discovered-domains.txt"
    # Автохостлист (Z2K_AUTOHOSTLIST=1): домены, которые движок нашёл сам,
    # подхватываются ЭТИМИ профилями — со всем арсеналом и ротацией РКН.
    # Профиль-детектор (в хвосте, см. ниже) только НАХОДИТ и дописывает имя в
    # файл; обходит уже rkn_tcp, потому что файл объявлен здесь обычным
    # хостлистом. Движок перечитывает списки по mtime, то есть обход для
    # найденного домена включается через секунды и без рестарта.
    local z2k_autohostlist autohostlist_file
    z2k_autohostlist=$(safe_config_read "Z2K_AUTOHOSTLIST" "${ZAPRET2_DIR:-/opt/zapret2}/config" "0")
    autohostlist_file="${ZAPRET2_DIR:-/opt/zapret2}/ipset/zapret-hosts-auto.txt"
    if [ "$z2k_autohostlist" = "1" ]; then
        # Файл обязан существовать К МОМЕНТУ СТАРТА демона: путь объявлен в
        # аргументах, а движок резолвит его при разборе и без файла не
        # стартует вовсе — это была бы не «автолист не работает», а «обход не
        # поднялся». Создаём здесь же, где объявляем, чтобы порядок вызовов в
        # init-скрипте не был единственной гарантией.
        mkdir -p "${ZAPRET2_DIR:-/opt/zapret2}/ipset" 2>/dev/null
        [ -e "$autohostlist_file" ] || : > "$autohostlist_file"
        rkn_lists_tail="$rkn_lists_tail --hostlist=${autohostlist_file}"
    fi
    # Единственное отличие TLS-профиля: Discord-домены живут на 443 и на 80-м
    # порту не встречаются.
    local rkn_hostlists="$rkn_lists_head"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${extra_strats_dir}/TCP_Discord.txt"
    rkn_hostlists="$rkn_hostlists$rkn_lists_tail"
    # ПОДСТАНОВКА ПОДОБРАННОГО ИМЕНИ В ФЕЙКОВЫЙ ClientHello.
    #
    # Лечит класс блокировки, который ротатор не берёт в принципе: рукопожатие
    # проходит, а поток встаёт на 12-24 КБ. Замер на роутере владельца:
    # hetzner.com отдавал ровно 15994 байта; тот же хост с фейком, несущим чужое
    # имя из белого списка провайдера, — 163654 за 0.5 с. Несущая часть — ИМЯ, а
    # не разрез: результат одинаков и с hostfakesplit, и с multisplit:seqovl=1.
    #
    # Имя подбирается В РАНТАЙМЕ (files/lua/z2k-alert.lua): детектор ловит обрыв
    # посреди TLS-записи, сдвигает хост на следующего кандидата из
    # lists/sni_wl_candidates.txt, и следующая попытка проверяет уже его.
    # Перебор идёт на трафике самого человека, отдельных проб нет.
    #
    # ДВЕ СТРОКИ, И ОБЕ ДО circular, БЕЗ strategy=N. Инстанс без этого аргумента
    # circular не вызывает вовсе — его исполняет линейный оркестратор. Значит имя
    # подставляется на ЛЮБОМ плече, а разрез продолжает ротироваться штатно.
    # Имя и разрез — разные оси, сваливать их в одно плечо неверно.
    #
    # Сами не отправляем: селектор только готовит блоб, шлёт ШТАТНЫЙ fake. Так
    # ttl, badsum, tcp_ts и repeats остаются в ведении движка, а `optional` даёт
    # тихий пропуск, пока имя не подобрано — у тех, кто на этот класс не
    # наткнулся, не происходит ничего.
    #
    # key и nld копируются из circular: возьми селектор другой ключ — он читал бы
    # не ту запись хоста, в которую пишет детектор.
    #
    # Считается ДО развилки «шаблон / плоская форма»: аварийный выключатель
    # шаблонов (Z2K_NFQWS2_TEMPLATES=0) не должен заодно выключать обход по
    # объёму. В плоской форме тот же блок вставляется перед circular вручную.
    local Z2K_SNI_STALL sni_pick="" _sp_circ="" _t2
    Z2K_SNI_STALL=$(safe_config_read "Z2K_SNI_STALL" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
    if [ -n "$rkn_circ" ]; then
        _sp_circ="$rkn_circ"
    else
        for _t2 in $rkn_tcp; do
            case "$_t2" in --lua-desync=circular:*) _sp_circ="$_t2"; break ;; esac
        done
    fi
    # ГЕЙТ ПО ИЗМЕРЕННОЙ ЛИНИИ, А НЕ ПО ДОГАДКЕ.
    #
    # Механизм осмыслен только там, где блокировка по объёму соединения есть.
    # Определять её по поведению чужого потока — источник ложных срабатываний:
    # горизонт видимости движка меряется в ПАКЕТАХ, и здоровая крупная
    # загрузка неотличима от обрыва (замер 30.08.2026: instagram отдал 404 КБ,
    # видно 17 КБ). Поэтому линию мерит отдельная проба по курируемым мишеням
    # (z2k-tcp16-probe.sh, метод runnin4ik/dpi-detector), а сюда приходит
    # готовый ответ.
    #
    # Файла нет — значит не мерили, и механизм выключен. Это единственное
    # умолчание, при котором человек без этого блока не получает ничего.
    local _sp_flag=""
    [ -r "${ZAPRET2_DIR:-/opt/zapret2}/state/tcp16.flag" ] &&
        _sp_flag=$(cat "${ZAPRET2_DIR:-/opt/zapret2}/state/tcp16.flag" 2>/dev/null)
    if [ "$Z2K_SNI_STALL" = "1" ] && [ "$_sp_flag" = "1" ] && [ -n "$_sp_circ" ]; then
        local _sp_k _sp_n
        _sp_k=$(printf '%s' "$_sp_circ" | sed -n 's/.*:\(key=[a-z_]*\).*/\1/p')
        _sp_n=$(printf '%s' "$_sp_circ" | sed -n 's/.*:\(nld=[0-9]*\).*/\1/p')
        # Наблюдение за обрывом — СВОИМ инстансом с dir=in. Внутрь детектора
        # его класть нельзя: детектор ротатора после защёлки успеха не
        # зовётся вовсе, и все 16 КБ прошли бы мимо. Проверено на живом
        # обрыве: circular отработал 48 раз, детектор — ни разу.
        # cap — потолок видимости в пакетах. Без него сторож принимал за обрыв
        # ЛЮБУЮ большую загрузку: поток уходит за потолок очереди, пакеты
        # перестают доходить, и молчание выглядит как остановка. Замер
        # 30.08.2026: chatgpt.com отдал 340 КБ, сторож увидел 17137 Б и записал
        # рабочему хосту чужое имя.
        local _sp_cap
        _sp_cap=$(z2k_reply_pkt_cap "$(safe_config_read "Z2K_USE_MID_STREAM_DETECTOR" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")")
        # СТОРОЖУ — СВОЙ, РАСШИРЕННЫЙ ДИАПАЗОН.
        #
        # Профиль ограничивает разбор первыми килобайтами ответа (--in-range),
        # и закрывающий пакет большой загрузки до инстанса не доходит вовсе:
        # замер 30.08.2026 — «in pos a0 s168082 ... is beyond range a0-s27500».
        # Ровно этот пакет и доказывает, что поток ехал за нашим горизонтом,
        # а без него сторож не мог отличить здоровую крупную загрузку от
        # обрыва и записывал рабочим хостам чужие имена.
        #
        # Диапазон — позиционное состояние разборщика: оно действует на всё,
        # что объявлено дальше. Поэтому сразу за нашим инстансом возвращаем
        # прежнее значение, иначе расширение утечёт на circular и сломает ему
        # планку inseq. Если в голове диапазона нет — не трогаем ничего:
        # восстанавливать было бы нечем.
        local _sp_ir="" _t3 _seen_circ=0
        for _t3 in $rkn_tcp; do
            case "$_t3" in
                --lua-desync=circular:*) _seen_circ=1; break ;;
                --in-range=*) _sp_ir="$_t3" ;;
            esac
        done
        [ "$_seen_circ" = "1" ] || _sp_ir=""
        sni_pick="${_sp_ir:+--in-range=a- }--lua-desync=z2k_stall_watch:dir=in:cap=${_sp_cap}${_sp_k:+:$_sp_k}${_sp_n:+:$_sp_n}${_sp_ir:+ $_sp_ir}"
        sni_pick="$sni_pick --lua-desync=z2k_sni_pick:payload=tls_client_hello:dir=out:blob=z2k_ch${_sp_k:+:$_sp_k}${_sp_n:+:$_sp_n}"
        sni_pick="$sni_pick --lua-desync=fake:payload=tls_client_hello:dir=out:blob=z2k_ch:optional:repeats=8:tcp_ts=-1000"
    fi

    if [ -n "$rkn_circ" ]; then
        add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" \
            "$wl_excl $rkn_hostlists $rkn_head $sni_pick $rkn_circ --import=$rkn_tpl --new"
    else
        # Плоская форма: тот же блок ставим перед первым circular. Позиция
        # обязательна — инстанс без strategy=N исполняет линейный оркестратор,
        # а он до аргументов ЗА ротатором не доходит.
        local rkn_flat="" _sp_done=0
        for _t2 in $rkn_tcp; do
            case "$_t2" in
                --lua-desync=circular:*)
                    if [ "$_sp_done" = "0" ] && [ -n "$sni_pick" ]; then
                        rkn_flat="${rkn_flat:+$rkn_flat }$sni_pick"
                        _sp_done=1
                    fi
                    ;;
            esac
            rkn_flat="${rkn_flat:+$rkn_flat }$_t2"
        done
        add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "$wl_excl $rkn_hostlists $rkn_flat --new"
    fi

    # cdn_tls профиль удалён 2026-04-27. Был добавлен в Variant A refactor
    # (b7f7ae6) для перехвата non-RKN CF/OVH/Hetzner/DO трафика, но на field
    # ломал то что и так работало через rkn_tcp (47-стратегий rotator
    # из Strategy.txt пробивал CF лучше чем 8 curated cdn_tls strategies).
    # CF возвращается под rkn_tcp как было до Variant A.

    # CF extra-check fallback (104.21.0.0/17). Подтверждённый wigeance
    # (ntc.party/t/726/9019, 2025-07): «На подсети 104.21.х.х CF у меня на
    # ТСПУ помимо 16кб, есть доп. проверка аналогичная *.googlevideo.com,
    # соответственно и обходится она аналогично». Профиль перехватывает
    # ВЕСЬ TLS-трафик на эту подсеть после rkn_tcp, чтобы покрыть CF-домены
    # которые НЕ в RKN-листе (random subdomains, обскурные сайты на CF Pro).
    # Whitelist юзера всё равно exclude. Использует тот же arsenal что rkn_tcp,
    # но с собственным circular key=cf_extra (отдельный nstrategy state, чтобы
    # не размывать выбор стратегии для основного rkn_tcp по другим доменам).
    # Live test 2026-05-08 (тестовый router): rkn_tcp probe rutracker.org →
    # 22/48 стратегий пробивают (≥240 kbps), значит arsenal достаточен.
    local Z2K_CF_EXTRA_CHECK
    Z2K_CF_EXTRA_CHECK=$(safe_config_read "Z2K_CF_EXTRA_CHECK" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
    if [ "$Z2K_CF_EXTRA_CHECK" = "1" ] && [ -s "${lists_dir}/cf_extra_check_ips.txt" ]; then
        if [ -n "$rkn_circ" ]; then
            # Копируется ТОЛЬКО circular-токен (в нём и есть отличие — key=),
            # арсенал приезжает импортом. Голова профиля повторяет голову
            # rkn_tcp намеренно: сегодня cf_extra наследует её из копии тела и
            # ловит все шесть портов, а не один 443 — убрать это здесь значило
            # бы тихо сузить профиль под видом рефакторинга.
            local cf_circ
            cf_circ=$(printf '%s' "$rkn_circ" | sed 's/key=rkn_tcp/key=cf_extra/')
            nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=443 --filter-l7=tls --ipset=${lists_dir}/cf_extra_check_ips.txt $wl_excl $rkn_head $cf_circ --import=$rkn_tpl --new\\n"
        else
            local cf_extra_strategies
            cf_extra_strategies=$(printf '%s' "$rkn_tcp" | sed 's/key=rkn_tcp/key=cf_extra/')
            nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=443 --filter-l7=tls --ipset=${lists_dir}/cf_extra_check_ips.txt $wl_excl $cf_extra_strategies --new\\n"
        fi
    fi

    # Phase 3 merge: YouTube + googlevideo collapsed to a single google_tls
    # profile. Hostlist triggers OR — hostlist=YT/List.txt ∪ hostlist-domains=
    # googlevideo.com (confirmed by hostlist.c:262-281). Circular pins per-SLD
    # thanks to nld=2, so youtube.com and googlevideo.com maintain independent
    # strategy picks even though they share the key=google_tls state.
    # GV strategies renumbered 23..44 to avoid collision with YT's 1..22.
    # Pre-Phase-3 else path keeps the legacy two-profile layout for rollback.
    if [ "$Z2K_REFACTOR_PHASE3" = "1" ]; then
        local youtube_gv_rebased
        youtube_gv_rebased=$(rebase_strategy_ids "$youtube_gv_tcp" 22)
        # Extract ONLY non-circular --lua-desync=* tokens from GV.
        # Global options (--filter-tcp, --filter-l7, --payload, --out-range,
        # --in-range) are dropped — youtube_tcp's own globals govern the
        # merged profile. Keeping GV globals would emit duplicate flags
        # (e.g. --filter-tcp=443 after --filter-tcp=443,2053,...) which
        # nfqws2 silently reinterprets as "last wins", shrinking the
        # effective port coverage of the merged profile.
        local gv_strategies_only=""
        local _tok
        for _tok in $youtube_gv_rebased; do
            case "$_tok" in
                --lua-desync=circular:*) ;;
                --lua-desync=*) gv_strategies_only="${gv_strategies_only:+$gv_strategies_only }$_tok" ;;
                *) ;;
            esac
        done
        local merged_google_tls
        merged_google_tls=$(printf '%s' "$youtube_tcp" | sed 's/key=yt_tcp/key=google_tls/')
        merged_google_tls="$merged_google_tls $gv_strategies_only"
        add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "$wl_excl --hostlist=${extra_strats_dir}/TCP/YT/List.txt --hostlist=${extra_strats_dir}/TCP/YT_GV/List.txt $merged_google_tls --new"
    else
        # YouTube TCP
        add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "$wl_excl --hostlist=${extra_strats_dir}/TCP/YT/List.txt $youtube_tcp --new"
        # YouTube GV — dedicated hostlist (extra_strats/TCP/YT_GV/List.txt,
        # содержит apex googlevideo.com → match всех поддоменов: rr1-rr9,
        # manifest, и т.д.). Расширяется добавлением строк в файл.
        add_hostlist_line "${extra_strats_dir}/TCP/YT_GV/List.txt" "$wl_excl --hostlist=${extra_strats_dir}/TCP/YT_GV/List.txt $youtube_gv_tcp --new"
    fi

    # QUIC YT
    add_hostlist_line "${extra_strats_dir}/UDP/YT/List.txt" "$wl_excl --hostlist=${extra_strats_dir}/UDP/YT/List.txt $quic_udp --new"

    # Discord TCP: currently disabled for autocircular profile set.
    if [ -n "$discord_tcp_block" ]; then
        add_hostlist_line "${extra_strats_dir}/TCP_Discord.txt" "$discord_tcp_block"
    fi

    # Discord UDP (no hostlist - STUN has no hostname, uses filter-l7=discord,stun
    # + hostkey=z2k_nohost_key for stable hostless rotation keying)
    nfqws2_opt_lines="$nfqws2_opt_lines$discord_udp --new\\n"

    # Здесь стоял webrtc_bypass — пустой профиль udp/1024-65535 × l7=stun,
    # который ничего не десинкал и служил щитом: он ловил P2P-STUN (WebRTC в
    # браузере, peer-to-peer голос Discord) РАНЬШЕ широкого профиля game_udp,
    # чтобы тот не выстрелил по нему фейками. Тот же класс проблемы, из-за
    # которого до него откатывали TCP-catchall игрового режима (2203de2:
    # фейки прилетали ответам LAN-клиентам и ядро рвало соединение RST'ом).
    #
    # Удалён: game_udp больше нет — игровой режим переехал на туннель WARP в
    # r-61.1 (d078a60), игры с IP-блоком маршрутизируются через Cloudflare, а
    # не десинкаются. Щит пережил то, от чего защищал: после discord_udp не
    # осталось ни одного широкого UDP-профиля, а в очередь и так заворачиваются
    # только порты из NFQWS2_PORTS_UDP (443 + диапазоны Discord).
    #
    # ЕСЛИ когда-нибудь снова появится широкий UDP-профиль после discord_udp
    # или NFQWS2_PORTS_UDP расширят на большой диапазон — щит нужно вернуть,
    # иначе P2P-голос и WebRTC поймают чужие фейки.

    # HTTP RKN (port 80): autocircular bypass of ISP DPI redirect (302 → block page).
    # 7 strategies from blockcheck2 results, ordered by simplicity.
    # standard_failure_detector detects HTTP 302 redirects natively.
    # --in-range=-s5556: let circular see HTTP response for failure detection.
    # Strategy 1: http_methodeol (simplest HTTP manipulation)
    # Strategy 2: syndata + multisplit
    # Strategy 3: hostfakesplit with TTL=2
    # Strategy 4: fake with badsum
    # Strategy 5: fakedsplit at method+2 with badsum
    # Strategy 6: z4r original (fake 0x0E + tcp_md5 + multisplit host+1)
    # Strategy 7: fake badsum + multisplit method+2
    # Тот же набор списков, что у TLS-профиля, минус Discord (см. сборку выше).
    # Отдельного второго сборщика здесь больше нет — именно он и разъезжался.
    local rkn_http_extras="$rkn_lists_tail"
    # native rollback 2026-05-28: http_rkn failure_detector=/success_detector=
    # инжекты z2k_* и no_http_redirect убраны. circular идёт на нативных
    # standard_failure_detector / standard_success_detector bol-van zapret2
    # (кастомные детекторы заархивированы, см. archive/). Нативная 302/307
    # redirect-детекция активна — block-page redirect снова считается fail.
    # http_rkn payload filter:
    #   http_req  — outgoing GET/POST (что строит модифицирующая стратегия)
    #   empty     — TCP control packets без payload (SYN/ACK сами по себе
    #                 проходят через standard_failure_detector RST-чек)
    #   http_reply — ИНКОМИНГ HTTP-ответ от сервера. Без этого профиль
    #                 фильтрует replies на entry, и detector chain никогда
    #                 не видит l7=http_reply → z2k_classify_http_reply
    #                 (commits 3-4 v3.6) становится dead code на всех
    #                 plain HTTP flows. Field-test 2026-04-30 показал 0
    #                 http_reply events за весь soak — добавили http_reply
    #                 чтобы классификатор реально видел ответы. Strategies
    #                 (multisplit/syndata/fake/etc) внутри scope-нуты на
    #                 payload=http_req, так что они не сработают на
    #                 incoming replies — только detectors классифицируют.
    http_rkn="--filter-tcp=80 $wl_excl --hostlist=${extra_strats_dir}/TCP/RKN/List.txt${rkn_http_extras} --in-range=-s5556 --payload=http_req,empty,http_reply --lua-desync=circular:fails=3:time=60:key=http_rkn:nld=2 --lua-desync=http_methodeol:payload=http_req:dir=out:strategy=1 --lua-desync=syndata:payload=http_req:dir=out:strategy=2 --lua-desync=multisplit:payload=http_req:dir=out:strategy=2 --lua-desync=hostfakesplit:payload=http_req:dir=out:ip_ttl=2:repeats=1:strategy=3 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=4 --lua-desync=fakedsplit:payload=http_req:dir=out:pos=method+2:badsum:strategy=5 --lua-desync=fake:payload=http_req:dir=out:blob=0x0E0E0F0E:tcp_md5:strategy=6 --lua-desync=multisplit:payload=http_req:dir=out:pos=host+1:seqovl=2:strategy=6 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=7 --lua-desync=multisplit:payload=http_req:dir=out:pos=method+2:strategy=7 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=8 --lua-desync=fakedsplit:payload=http_req:dir=out:pos=method+2:ip_autottl=2,1-64:badsum:strategy=8 --in-range=x --new"

    # Обёртка нужна и здесь. Пул объявляется НИЖЕ блока проводки TLS-пулов, и
    # до 19.08.2026 его туда просто забыли добавить: после среза кастомных
    # детекторов http_rkn оставался на голом standard_failure_detector без
    # единого гварда. Цена — apple.com уехал с рабочей первой стратегии на
    # вторую на живом трафике, замер тем же вечером:
    #   standard_failure_detector: incoming RST s524 in range s4096   x13/мин
    # RST после 524 байт ответа — это сервер закрылся сам, а не DPI. Обёртка
    # отсеивает такие по TTL и по живости хоста; исходящий ретрансмит она
    # пропускает в штатный детектор на http_req ровно так же, как на
    # ClientHello, поэтому детект молчаливого дропа не теряется.
    if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/lua/z2k-alert.lua" ]; then
        http_rkn=$(ensure_rkn_failure_detector "$http_rkn" "z2k_fail_tls_alert")
    fi
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "$http_rkn"

    # --------------------------------------------------------------------------
    # WHATSAPP NOISE (TCP/5222) — расщепление первого пакета рукопожатия
    # --------------------------------------------------------------------------
    # Настольный WhatsApp связывается со шлюзом g.whatsapp.net своим протоколом
    # Noise, а не TLS: ни ClientHello, ни SNI, ни имени хоста в пакете нет.
    # Первые четыре байта — открытая сигнатура "WA\x06\x03", и ровно по ней
    # ТСПУ дропает первый пакет с данными: TCP-рукопожатие проходит, сорок байт
    # уходят, ответа ноль, клиент через десять секунд аннулирует QR-код и
    # заходит по кругу. В его собственном журнале это видно дословно:
    #   handshake_manager/timeout [timeout=10s, bytesSent=40, bytesReceived=0]
    #
    # Замер 2026-08-28 на живой линии, настоящим прологом из дампа, по три
    # повтора на точку разреза (и по шесть на pos=1,2 через релей):
    #   целиком        — тишина
    #   pos=1,2,3      — ответ 350 байт, 21 из 21
    #   pos=4,5,6,8,12 — тишина
    # Сигнатура ровно в первых четырёх байтах: разрез ВНУТРИ них её ломает,
    # разрез после — нет. Отсюда pos=1.
    #
    # Хостлиста тут быть не может — имени в протоколе нет вовсе, поэтому фильтр
    # только по порту. Ротации тоже нет: плечо одно и оно доказано, а перебор
    # недоказанных плеч на рукопожатии, которое клиент повторяет раз в две
    # минуты, стоил бы человеку четверти часа ожидания вместо связи.
    #
    # --out-range=-s64 держит в очереди только само рукопожатие: дальше поток
    # уже зашифрован и трогать его незачем.
    # Профиль намеренно голый. Первая редакция несла ещё --hostlist-exclude
    # и --out-range=-s64 — и не выбиралась движком вовсе: в отладке стояло
    # «desync profile 0 (no_action) matches», решение кэшировалось на
    # ip:port, и расщепление не выполнялось ни разу. Ограничивать поток тут
    # нечем и незачем: в очередь и так попадают только первые 20 исходящих
    # пакетов соединения (connbytes в правиле NFQUEUE), а хостлист без
    # имени хоста бессмыслен.
    wa_noise="--filter-tcp=5222 --payload=unknown --lua-desync=multisplit:payload=unknown:dir=out:pos=1 --new"
    nfqws2_opt_lines="$nfqws2_opt_lines$wa_noise\\n"

    # --------------------------------------------------------------------------
    # АВТОХОСТЛИСТ: профиль-детектор (только при Z2K_AUTOHOSTLIST=1)
    # --------------------------------------------------------------------------
    #
    # Тумблер «Автохостлист» существовал с r-45 и до сих пор не доходил до
    # движка вовсе: апстрим подставляет --hostlist-auto только заменой
    # плейсхолдера <HOSTLIST> (common/list.sh), а мы генерируем профили с
    # явными путями и плейсхолдеров не используем. Аргументы демона в обоих
    # положениях тумблера были байт в байт одинаковы — человеку при этом в
    # трёх местах обещано, что «движок сам находит заблокированные домены».
    #
    # ПОЧЕМУ ОТДЕЛЬНЫЙ ПРОФИЛЬ И ПОЧЕМУ В ХВОСТЕ. Профиль с --hostlist-auto
    # выигрывает подбор при ЛЮБОМ известном имени хоста, независимо от своих
    # списков (nfq2/desync.c: «autohostlist profile ... always win if we have a
    # hostname»), а подбор останавливается на первом совпадении. Повесить флаг
    # на rkn_tcp — значит отдать ему youtube.com и googlevideo.com: профили
    # yt_tcp/gv_tcp стоят ниже с тем же фильтром портов и живут только за счёт
    # непересекающихся хостлистов. Поэтому детектор — последний профиль:
    # ему достаётся ровно то, что не разобрали профили выше.
    #
    # ПОЧЕМУ БЕЗ СТРАТЕГИЙ. К хосту вне списков десинк не применяется в любом
    # случае (движок помнит отрицательный результат проверки списков), поэтому
    # инстансы здесь были бы мёртвым грузом: детектор считает неудачи, пишет
    # имя в файл, а обходит уже rkn_tcp — файл подключён к нему хостлистом
    # выше. Заодно не дублируется 13 КБ арсенала в командной строке.
    if [ "$z2k_autohostlist" = "1" ]; then
        # Порты берём из самого rkn_tcp, а не литералом: набор задаётся в
        # lib/strategies.sh и уже расходился с копиями в других местах.
        local ah_ports
        ah_ports=$(printf '%s' "$rkn_tcp" | sed -n 's/.*--filter-tcp=\([0-9,-]*\).*/\1/p' | head -1)
        [ -n "$ah_ports" ] || ah_ports="443,2053,2083,2087,2096,8443"

        # Пороги детектора. Пустое значение = дефолт движка (3 неудачи за 60 с
        # и т.д.), поэтому каждый флаг добавляется ТОЛЬКО если человек задал
        # его в config — командная строка не растёт зря, а дефолты остаются
        # там, где их сопровождает автор движка.
        local ah_tune="" ah_key ah_val ah_flag
        for ah_key in FAIL_THRESHOLD:fail-threshold FAIL_TIME:fail-time \
                      RETRANS_THRESHOLD:retrans-threshold RETRANS_RESET:retrans-reset \
                      RETRANS_MAXSEQ:retrans-maxseq INCOMING_MAXSEQ:incoming-maxseq \
                      UDP_IN:udp-in UDP_OUT:udp-out; do
            ah_val=$(safe_config_read "AUTOHOSTLIST_${ah_key%%:*}" "${ZAPRET2_DIR:-/opt/zapret2}/config" "")
            [ -n "$ah_val" ] || continue
            ah_flag="${ah_key#*:}"
            ah_tune="$ah_tune --hostlist-auto-${ah_flag}=${ah_val}"
        done
        # Отладочный лог движка — параметр глобальный, не профильный. Наружу
        # не выставлен намеренно: включаем его мы, разбирая конкретный тикет.
        if [ "$(safe_config_read "AUTOHOSTLIST_DEBUGLOG" "${ZAPRET2_DIR:-/opt/zapret2}/config" "0")" = "1" ]; then
            ah_tune="$ah_tune --hostlist-auto-debug=${ZAPRET2_DIR:-/opt/zapret2}/ipset/zapret-hosts-auto-debug.log"
        fi

        nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=${ah_ports} --filter-l7=tls $wl_excl --hostlist-auto=${autohostlist_file}${ah_tune} --new\\n"
    fi

    # Шаблон ставится В ГОЛОВУ и только если его кто-то импортирует: ссылка
    # вперёд движком не поддерживается, а объявленный и никем не использованный
    # шаблон — это просто мусор в конфиге, который человек читает при разборе
    # тикетов.
    if [ -n "$rkn_tpl_line" ]; then
        case "$nfqws2_opt_lines" in
            *"--import=$rkn_tpl"*)
                nfqws2_opt_lines="$rkn_tpl_line\\n$nfqws2_opt_lines" ;;
        esac
    fi

    local nfqws2_opt_value
    nfqws2_opt_value=$(printf "%b" "$nfqws2_opt_lines" | sed '/^$/d')
    # Each profile-line ends with --new (separator before the next profile).
    # The very last --new has no profile after it — nfqws2 parses it as an
    # empty trailing profile (no filter, no hostlist, no desync). Strip it.
    nfqws2_opt_value=$(printf '%s' "$nfqws2_opt_value" | sed '$ s/[[:space:]]*--new[[:space:]]*$//')
    cat <<NFQWS2_OPT
NFQWS2_OPT="
$nfqws2_opt_value
"
NFQWS2_OPT
}

# ==============================================================================
# СОЗДАНИЕ ОФИЦИАЛЬНОГО CONFIG ФАЙЛА
# ==============================================================================

# Потолок видимости входящего потока В ПАКЕТАХ: сколько ответных пакетов
# iptables отдаёт в очередь (NFQWS2_TCP_PKT_IN, `--connbytes 1:N ... dir reply`).
# Дальше него движок не видит НИЧЕГО — ни данных, ни FIN, — и молчание там
# ничего не означает.
#
# Число нужно в двух местах: в теле конфига и в аргументе сторожа обрыва,
# который по нему отличает «поток встал» от «мы ослепли». Разъедься эти два
# места — сторож начнёт судить вслепую, поэтому значение живёт в одной функции.
z2k_reply_pkt_cap() {
    # 50, а не 30: замер на боевом роутере 18.08.2026 — при 30 пакетах ответа
    # наблюдение обрывалось около 20 КБ (первые пакеты потока мелкие: записи
    # рукопожатия, кадры HTTP/2), а порог успеха inseq у rkn_tcp стоит на 26000,
    # и успех не срабатывал НИ РАЗУ — счётчик провалов было нечем обнулять.
    # С 50 глубина дошла до 26849 и успех наконец сработал. Цена того же
    # прогона: +28% пакетов в очередь, +9% процессорного времени, дропов 0.
    # При флаге 0 остаётся master-совместимая десятка: видно только рукопожатие.
    if [ "$1" = "1" ]; then echo 50; else echo 10; fi
}

create_official_config() {
    # $1 - путь к config файлу (обычно /opt/zapret2/config)

    local config_file="${1:-/opt/zapret2/config}"

    print_info "Создание официального config файла: $config_file"

    # Создать директорию если не существует
    mkdir -p "$(dirname "$config_file")"

    # Генерировать NFQWS2_OPT. `$(...)` съедает return-код функции, поэтому
    # проверяем его отдельно: порченый Strategy.txt (0xFF-мусор с мёртвого
    # NAND-блока) роняет генерацию здесь, ДО записи в конфиг — так живой
    # config_file и работающий сервис остаются нетронутыми.
    local nfqws2_opt_section
    nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies) || return 1

    # =========================================================================
    # ВАЛИДАЦИЯ NFQWS2 ОПЦИЙ (ВАЖНО)
    # =========================================================================
    print_info "Валидация сгенерированных опций nfqws2..."

    # Извлечь NFQWS2_OPT из сгенерированной секции (многострочный heredoc между кавычками)
    local nfqws2_opt_value
    nfqws2_opt_value=$(echo "$nfqws2_opt_section" | sed -n '/^NFQWS2_OPT="/,/^"$/{ /^NFQWS2_OPT="/d; /^"$/d; p; }')

    # Загрузить модули для dry_run_nfqws()
    if [ -f "/opt/zapret2/common/base.sh" ]; then
        . "/opt/zapret2/common/base.sh"
    fi

    if [ -f "/opt/zapret2/common/linux_daemons.sh" ]; then
        . "/opt/zapret2/common/linux_daemons.sh"

        # Установить временно NFQWS2_OPT для проверки
        export NFQWS2_OPT="$nfqws2_opt_value"
        export NFQWS2="/opt/zapret2/nfq2/nfqws2"

        # Проверить опции (dry_run может ложно падать если lua/blob файлы
        # ещё не установлены — это нормально при первой установке)
        if command -v dry_run_nfqws >/dev/null 2>&1; then
            if dry_run_nfqws 2>/dev/null; then
                print_success "Опции nfqws2 валидны (dry-run OK)"
            else
                print_info "dry-run nfqws2 не прошёл (нормально при установке — lua/blob файлы подключатся при запуске)"
            fi
        fi
    else
        print_info "Модули валидации не найдены, пропускаем проверку"
    fi

    z2k_have_cmd() { command -v "$1" >/dev/null 2>&1; }

    # Получить FWTYPE и FLOWOFFLOAD из окружения (если установлены)
    local fwtype_value="${FWTYPE:-iptables}"
    local flowoffload_value="${FLOWOFFLOAD:-none}"
    local tmpdir_value="${TMPDIR:-}"

    # ==============================================================================
    # IPv6 auto-detect (Keenetic)
    # ==============================================================================
    # Default behavior historically was DISABLE_IPV6=1 because many Keenetic builds
    # don't ship ip6tables. Here we enable IPv6 only if:
    # - IPv6 looks configured (default route or global address exists)
    # - and the firewall backend can actually handle IPv6 rules:
    #   - iptables => ip6tables must exist
    #   - nftables => nft must exist
    local disable_ipv6_value="${DISABLE_IPV6:-}"
    # PRESERVE policy (Mark 2026-06-20): на апдейте НИКОГДА не включаем и не
    # выключаем IPv6 — берём значение как есть. Часть юзеров правит DISABLE_IPV6
    # руками; автодетект имеет право решать ТОЛЬКО на чистой установке, где
    # прежнего значения нет нигде. Источник по приоритету:
    #   env override > config_file, который сейчас пишем > config прежней
    #   установки (живой ИЛИ его .old.$$ бэкап от текущей переустановки).
    if [ -z "$disable_ipv6_value" ] && [ -f "$config_file" ]; then
        disable_ipv6_value=$(safe_config_read "DISABLE_IPV6" "$config_file" "")
    fi
    # Auto-update reinstall строит config_file с нуля (step_build_zapret2
    # переносит старое дерево в .old.$$ ДО генерации конфига), поэтому чтение
    # выше на первом проходе пустое и старый код тут сваливался в автодетект —
    # т.е. сам включал/выключал v6 вместо сохранения. Достаём прежнее значение
    # из живого конфига или самого свежего .old.$$ бэкапа, чтобы автодетект
    # ниже не перетёр пользовательскую настройку посреди переустановки.
    if [ -z "$disable_ipv6_value" ]; then
        local _zd_ipv6="${ZAPRET2_DIR:-/opt/zapret2}"
        local _prior_cfg
        # shellcheck disable=SC2045,SC2046
        for _prior_cfg in "${_zd_ipv6}/config" $(ls -dt "${_zd_ipv6}".old.*/config 2>/dev/null); do
            [ -f "$_prior_cfg" ] || continue
            [ "$_prior_cfg" = "$config_file" ] && continue
            disable_ipv6_value=$(safe_config_read "DISABLE_IPV6" "$_prior_cfg" "")
            [ -n "$disable_ipv6_value" ] && break
        done
    fi
    if [ -z "$disable_ipv6_value" ]; then
        disable_ipv6_value="1"
        local v6_ok="0"
        if z2k_have_cmd ip; then
            ip -6 route show default 2>/dev/null | grep -q . && v6_ok="1"
            if [ "$v6_ok" = "0" ]; then
                ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && v6_ok="1"
            fi
        fi

        if [ "$v6_ok" = "1" ]; then
            if [ "$fwtype_value" = "nftables" ]; then
                if z2k_have_cmd nft; then
                    disable_ipv6_value="0"
                    print_info "IPv6 обнаружен, backend=nftables: включаем обработку IPv6 (DISABLE_IPV6=0)"
                else
                    print_info "IPv6 обнаружен, но nft не найден: оставляем IPv6 отключенным (DISABLE_IPV6=1)"
                fi
            else
                if z2k_have_cmd ip6tables; then
                    disable_ipv6_value="0"
                    print_info "IPv6 обнаружен, backend=iptables: включаем обработку IPv6 (DISABLE_IPV6=0)"
                else
                    print_info "IPv6 обнаружен, но ip6tables не найден: оставляем IPv6 отключенным (DISABLE_IPV6=1)"
                fi
            fi
        else
            print_info "IPv6 не обнаружен (нет default route/global addr): оставляем IPv6 отключенным (DISABLE_IPV6=1)"
        fi
    else
        print_info "DISABLE_IPV6 сохранён как есть (апдейт IPv6 не трогает): DISABLE_IPV6=$disable_ipv6_value"
    fi

    # Сохранить пользовательские настройки из существующего конфига
    local saved_GAME_WARP_ENABLED="0"
    local saved_TG_PROXY_USER_DISABLED="0"
    local saved_ENABLED="1"
    local saved_Z2K_USE_MID_STREAM_DETECTOR="1"
    local saved_Z2K_PADENCAP="1"
    local saved_Z2K_NFQWS2_TEMPLATES="1"
    local saved_Z2K_INJECT_TLS_MODS="0"
    local saved_Z2K_DISCOVER="0"
    local saved_Z2K_DYNAMIC_TTL="1"
    local saved_Z2K_INSTA_DNS="1"
    local saved_Z2K_STATS="1"
    local saved_Z2K_STATS_ACK="0"
    local saved_DISABLE_CUSTOM="1"
    local saved_POLICY_NAME="nfqws"
    local saved_POLICY_EXCLUDE="0"
    local _pn_q="" _pe_q=""   # те же значения, экранированные под одинарные кавычки
    local saved_Z2K_PPE_DEOFFLOAD="1"
    local saved_Z2K_PPE_DEOFFLOAD_QUIC="1"
    # Вход в панель по паролю. Умолчание 0 — выключено; панель годами ставили
    # без пароля, и регенерация конфига не должна его однажды включить.
    #
    # ПОЧЕМУ ЭТОТ КЛЮЧ ОБЯЗАН БЫТЬ ЗДЕСЬ. Генератор пишет конфиг С НУЛЯ по
    # фиксированному списку и подменяет боевой файл. Ключ, которого в списке
    # нет, ИСЧЕЗАЕТ — а set_flag из панели и меню дописывает его в конец. То
    # есть без этой строки пароль снимался сам: достаточно щёлкнуть любой
    # тумблер в панели (каждый зовёт regenerate_config) или дождаться ночного
    # обновления, и панель молча открыта всем в локальной сети, причём
    # владельцу об этом никто не сообщит. Выключатель безопасности, который
    # выключается сам, хуже его отсутствия.
    local saved_Z2K_PANEL_AUTH="0"
    # Автообновление ночью. Умолчание 1 — как было всегда.
    #
    # Ключ пропал из этого списка и стоил нам issue #38 «Бесполезная кнопка
    # отключения авто обновлений». Механика ровно та же, что описана абзацем
    # выше: панель дописывает Z2K_AUTO_UPDATE_ENABLED=0 в конец конфига, а
    # следующая регенерация пишет файл заново по списку, ключа в нём нет, он
    # исчезает — и read_flag возвращает умолчание, то есть «включено».
    # Регенерацию вызывает любой другой тумблер панели и само ночное
    # обновление, поэтому выключение не переживало ни одного цикла.
    local saved_Z2K_AUTO_UPDATE_ENABLED="1"
    if [ -f "$config_file" ]; then
        saved_GAME_WARP_ENABLED=$(safe_config_read "GAME_WARP_ENABLED" "$config_file" "0")
        saved_TG_PROXY_USER_DISABLED=$(safe_config_read "TG_PROXY_USER_DISABLED" "$config_file" "0")
        # ENABLED — master service on/off gate (read by S99zapret2.new start()).
        # Was hardcoded =1 below and NOT preserved, so a user who stopped the
        # service (ENABLED=0) saw it resurrected by the next config regen
        # (auto-update reinstall / any toggle / reboot). Now preserved like
        # DISABLE_CUSTOM. Default 1: fresh install or a config missing the key
        # comes up enabled, so users who never stopped are unaffected.
        saved_ENABLED=$(safe_config_read "ENABLED" "$config_file" "1")
        # Z2K_USE_MID_STREAM_DETECTOR / Z2K_PADENCAP — default ON (per Mark
        # 2026-05-02 policy: все нововведения по умолчанию включены). Если
        # старый config не содержит ключ, считаем "1" — фичу хочется
        # включить даже на routers где конфиг был сгенерирован до её
        # появления. Юзер может выставить =0 explicitly чтобы откатиться.
        saved_Z2K_USE_MID_STREAM_DETECTOR=$(safe_config_read "Z2K_USE_MID_STREAM_DETECTOR" "$config_file" "1")
        saved_Z2K_PADENCAP=$(safe_config_read "Z2K_PADENCAP" "$config_file" "1")
        saved_Z2K_NFQWS2_TEMPLATES=$(safe_config_read "Z2K_NFQWS2_TEMPLATES" "$config_file" "1")
        saved_Z2K_INJECT_TLS_MODS=$(safe_config_read "Z2K_INJECT_TLS_MODS" "$config_file" "0")
        # Z2K_DISCOVER — умолчание 0, и ключ обязан ПЕРЕЖИВАТЬ перегенерацию.
        # Его тут не было вовсе: генератор ключ не сохранял, установка потом
        # дописывала «Z2K_DISCOVER=0», и включённая вручную автодетекция
        # сбрасывалась при каждом обновлении (issue #44).
        saved_Z2K_DISCOVER=$(safe_config_read "Z2K_DISCOVER" "$config_file" "0")
        # Z2K_AUTOHOSTLIST — default 0, deliberately against the "new flags come
        # on" rule. It does not improve behaviour, it swaps the filtering mode
        # for ALL traffic: nfqws2 starts deciding for itself which hosts are
        # blocked and appends them to the RKN list. That was asked for as an
        # option, not as a change for everyone.
        saved_Z2K_AUTOHOSTLIST=$(safe_config_read "Z2K_AUTOHOSTLIST" "$config_file" "0")
        saved_Z2K_DYNAMIC_TTL=$(safe_config_read "Z2K_DYNAMIC_TTL" "$config_file" "1")
        saved_Z2K_INSTA_DNS=$(safe_config_read "Z2K_INSTA_DNS" "$config_file" "1")
        # Z2K_STATS — anonymized strategy telemetry to VPS, default ON (per Mark
        # 2026-05-30: Default ON как все фичи). Opt-out via menu/webpanel toggle
        # sets =0; preserved across auto-update by the Z2K_ prefix rule.
        saved_Z2K_STATS=$(safe_config_read "Z2K_STATS" "$config_file" "1")
        # Признак «человек видел, что именно уходит». Ноль означает «ещё не
        # показывали»: первая отправка подождёт (см. files/z2k-stats-upload.sh).
        # У уже работающей установки ключа нет — тогда единица, заново
        # спрашивать того, кто давно живёт с телеметрией, незачем.
        saved_Z2K_STATS_ACK=$(safe_config_read "Z2K_STATS_ACK" "$config_file" "1")
        # DISABLE_CUSTOM — custom.d on/off (inverse: 0 = custom.d enabled). Was
        # hardcoded =1 in the generated config and NOT preserved, so enabling
        # custom.d (menu [S] / webpanel) survived only until the next config
        # regen (any other toggle / auto-update) silently re-disabled it. Now
        # preserved like the other knobs.
        saved_DISABLE_CUSTOM=$(safe_config_read "DISABLE_CUSTOM" "$config_file" "1")
        # Keenetic policy integration (см. S99zapret2.new:919-1100). По умолчанию
        # nfqws=POLICY_NAME, exclude=0 (= "process only this policy"); если юзер
        # явно настроил bypass конкретного устройства через создание политики +
        # POLICY_EXCLUDE=1 в config'е — preserve'им через reinstall.
        saved_POLICY_NAME=$(safe_config_read "POLICY_NAME" "$config_file" "nfqws")
        saved_POLICY_EXCLUDE=$(safe_config_read "POLICY_EXCLUDE" "$config_file" "0")
        # Z2K_PPE_DEOFFLOAD(_QUIC) — Keenetic per-flow hardware-offload exclusion
        # toggles (webpanel toggle_ppe). Default 1=ON. Were NOT preserved, so the
        # toggle's own regenerate_config wiped the key → NDM hook 94 re-added the
        # de-offload rules → the webpanel switch silently reverted after a regen /
        # reboot. Now preserved like the other knobs (same class as DISABLE_CUSTOM
        # and the r-56.6 DISABLE_IPV6 fix).
        saved_Z2K_PPE_DEOFFLOAD=$(safe_config_read "Z2K_PPE_DEOFFLOAD" "$config_file" "1")
        saved_Z2K_PPE_DEOFFLOAD_QUIC=$(safe_config_read "Z2K_PPE_DEOFFLOAD_QUIC" "$config_file" "1")
        saved_Z2K_PANEL_AUTH=$(safe_config_read "Z2K_PANEL_AUTH" "$config_file" "0")
        saved_Z2K_AUTO_UPDATE_ENABLED=$(safe_config_read "Z2K_AUTO_UPDATE_ENABLED" "$config_file" "1")
    fi

    # NFQWS2_TCP_PKT_IN — глубина наблюдения за ответом. Само число и повод
    # для него лежат в z2k_reply_pkt_cap: его читает и сторож обрыва, и потому
    # оно обязано быть одним.
    local nfqws2_tcp_pkt_in
    nfqws2_tcp_pkt_in=$(z2k_reply_pkt_cap "$saved_Z2K_USE_MID_STREAM_DETECTOR")

    # Создать полный config файл
    local z2k_mode_filter=hostlist
    [ "${saved_Z2K_AUTOHOSTLIST:-0}" = "1" ] && z2k_mode_filter=autohostlist

    # Пороги детектора автохостлиста. Наружу не выставлены: их не крутит ни
    # меню, ни панель — это ручка для разбора конкретного тикета. В конфиге
    # они лежат закомментированными вместе с дефолтами движка, чтобы было
    # видно, что вообще можно подкрутить и каким значением; раскомментированное
    # переживает регенерацию, как и всё остальное, что задал человек.
    #
    # Значение чистим до цифр: строка уходит и в аргументы демона, и обратно в
    # конфиг, который сорсится от root. Апостроф в числовом поле — это не
    # злоумышленник, это опечатка, но сервис от неё не поднимется.
    local _ah_block="" _ah_pair _ah_name _ah_def _ah_cur
    for _ah_pair in FAIL_THRESHOLD=3 FAIL_TIME=60 RETRANS_THRESHOLD=3 RETRANS_RESET=1 \
                    RETRANS_MAXSEQ=32768 INCOMING_MAXSEQ=4096 UDP_IN=1 UDP_OUT=4 DEBUGLOG=0; do
        _ah_name="AUTOHOSTLIST_${_ah_pair%%=*}"
        _ah_def="${_ah_pair#*=}"
        _ah_cur=$(safe_config_read "$_ah_name" "$config_file" "")
        _ah_cur=$(printf '%s' "$_ah_cur" | tr -dc '0-9')
        if [ -n "$_ah_cur" ]; then
            _ah_block="${_ah_block}${_ah_name}=${_ah_cur}
"
        else
            _ah_block="${_ah_block}#${_ah_name}=${_ah_def}
"
        fi
    done

    # Пишем во ВРЕМЕННЫЙ файл, а боевой подменяем одним rename в самом конце.
    #
    # Ниже конфиг собирается десятком отдельных `>>`. Раньше они шли прямо в
    # боевой файл, и любой обрыв в середине (полный /opt, умирающий NAND —
    # прецедент с 0xFF-мусором в Strategy.txt был) оставлял ПОЛУКОНФИГ, который
    # S99zapret2 сорсит на следующем бутe от root. Функция при этом печатала
    # «Config файл создан» и возвращала 0.
    #
    # Все чтения саженных значений (safe_config_read выше) уже отработали по
    # боевому файлу, так что подмена цели здесь безопасна.
    local _cfg_target="$config_file"
    config_file="${_cfg_target}.new.$$"
    rm -f "$config_file"

    cat > "$config_file" <<CONFIG
# zapret2 configuration for Keenetic
# Generated by z2k installer
# Based on official zapret2 config structure

# ==============================================================================
# BASIC SETTINGS
# ==============================================================================

# Enable zapret2 service
ENABLED=${saved_ENABLED}

# Mode filter: none, ipset, hostlist, autohostlist
# Default is hostlist — domains come from explicit hostlist files. With
# Z2K_AUTOHOSTLIST=1 the engine switches to autohostlist and works out the
# blocked hosts itself (see ensure_autohostlist_files / sync_autohostlist_to_rkn
# in S99zapret2), appending what it finds to the RKN list.
MODE_FILTER=${z2k_mode_filter}
Z2K_AUTOHOSTLIST=${saved_Z2K_AUTOHOSTLIST}

# Автодетекция блокировок (демон z2k-detect, пункт [Y] в меню).
# ФУНКЦИЯ ОПЫТНАЯ, по умолчанию выключена и на эксплуатацию не рассчитана.
# Ключ сохраняется между перегенерациями: включённый вручную режим не должен
# сбрасываться обновлением.
Z2K_DISCOVER=${saved_Z2K_DISCOVER}

# Пороги детектора автохостлиста. Действуют только при Z2K_AUTOHOSTLIST=1.
# Закомментировано = значение по умолчанию самого движка (показано справа).
# FAIL_THRESHOLD — сколько неудач подряд заносят хост в список
# FAIL_TIME — за сколько секунд от ПЕРВОЙ неудачи они должны уложиться
# RETRANS_* — что считать неудачей по TCP-ретрансмиссиям
# INCOMING_MAXSEQ — до какого места во входящем потоке ищется RST/редирект
# UDP_IN/UDP_OUT — критерий неудачи для QUIC/UDP
# DEBUGLOG=1 — построчный лог решений детектора (пишется на флеш, включать точечно)
${_ah_block}

# Firewall type - AUTO-DETECTED by init script, DO NOT set manually
# Init script calls linux_fwtype() which detects iptables/nftables automatically
# If FWTYPE is set here, linux_fwtype() will skip detection!
#FWTYPE=iptables

# ==============================================================================
# NFQWS2 DAEMON SETTINGS
# ==============================================================================

# Enable nfqws2
NFQWS2_ENABLE=1

# TCP ports to process (will be filtered by --filter-tcp in NFQWS2_OPT).
# Base only: HTTP/HTTPS + Cloudflare alternates. game_mode hybrid/aggressive
# used to append 1024-65535 here to feed a catch-all TCP profile, but that
# profile also matched the router's OUTPUT replies to LAN clients and
# broke the web UI — removed 2026-04-24.
# 5222 — шлюз WhatsApp (Noise поверх TCP). Без него пакеты рукопожатия не
# попадают в NFQUEUE вовсе, и расщепить их нечем: см. профиль wa_noise.
NFQWS2_PORTS_TCP="80,443,2053,2083,2087,2096,5222,8443"

# UDP ports to process (will be filtered by --filter-udp in NFQWS2_OPT)
NFQWS2_PORTS_UDP="443,50000-50099,1400,3478-3481,5349,19294-19344"

# Discord voice/STUN: KEEPALIVE DISABLED (empty) — по канону bol-van.
# Раньше (2026-06-11) на discord-портах connbytes-лимит снимался (keepalive),
# и dbankcloud-fake летел на КАЖДЫЙ исходящий пакет флоу. Это ломало видео-стрим:
# непрерывный decoy перед каждым медиапакетом → пинг 5000 сразу при старте стрима.
# bol-van (#4450): "на linux нас спасёт connbytes" — медиапоток нельзя гнать
# через NFQUEUE целиком; пробивается маленьким cutoff на старте, не keepalive'ом.
# Теперь discord-порты идут под стандартным connbytes 1:5 (NFQWS2_PORTS_UDP) +
# --out-range=-d4 в самой стратегии (тугой cutoff, #1267 "n2 или d2 лучше").
# Голос пробивается на старте, стрим не страдает. Пусто = keepalive-правил нет.
NFQWS2_PORTS_UDP_KEEPALIVE=""

# Packet direction filters (connbytes)
# NOTE: These are packet counts, NOT ranges
# PKT_OUT=20 means "first 20 packets" (connbytes 1:20)
# Official zapret2 defaults: TCP_PKT_OUT=20, UDP_PKT_OUT=5
NFQWS2_TCP_PKT_OUT="20"
NFQWS2_TCP_PKT_IN="${nfqws2_tcp_pkt_in}"
# UDP-окно: 8/8 вместо апстримных 5/3.
#
# Замер 2026-08-19 на боевом роутере, 1646 QUIC-потоков. Окно в 3 входящих
# НЕ ДЕРЖИТ: в журнале есть потоки с семью и более входящими, дошедшими до
# демона. Причина — kernel-conntrack по UDP протухает за 30 секунд, запись
# пересоздаётся, connbytes считает заново, а собственный ctrack демона живёт
# 60 секунд (CTRACK_T_UDP) и продолжает копить. То есть счётчики у нас
# работают благодаря протуханию conntrack, а не вопреки ему.
#
# Полагаться на это нельзя: на роутере с другими таймаутами окно окажется
# жёстким потолком в 3 пакета, и порог успеха udp_in станет недостижим —
# получим ровно тот баг, который здесь и чиним (успех не срабатывает никогда,
# провалы копятся без сброса, страта ротируется на здоровом трафике).
#
# Мануал, «Обслуживание позиций»: «Счетчик не может и не будет считать то,
# что не перехватывается», и там же у детекторов: «требуют перенаправления
# входящего и исходящего трафика в объеме, необходимом для срабатывания их
# критериев». В собственном примере правил перехвата мануал ставит
# MAX_PKT_IN=15 и MAX_PKT_OUT=15 одинаково для TCP и UDP, так что 8 —
# осторожная величина, а не смелая. TCP у нас давно 50/20.
#
# Инвариант, который обязан держаться: окно > порога детектора.
#   yt_quic   udp_in=3 udp_out=5   -> нужно >=6, ставим 8
#   discord   udp_in=1 udp_out=4   -> нужно >=5, ставим 8
NFQWS2_UDP_PKT_OUT="${Z2K_UDP_PKT_OUT}"
NFQWS2_UDP_PKT_IN="${Z2K_UDP_PKT_IN}"

# ==============================================================================
# NFQWS2 OPTIONS (MULTI-PROFILE MODE)
# ==============================================================================
# This section is auto-generated from z2k strategy database
# Each --new separator creates independent profile with own filters and strategy
# Order: RKN TCP → YouTube TCP → YouTube GV → QUIC YT → Discord UDP → HTTP RKN → Catch-all TCP
# Profiles use explicit hostlists from z2k list files without placeholder expansion.
# This avoids mixing with global hostlists from MODE_FILTER.
CONFIG

    # Добавить сгенерированный NFQWS2_OPT
    echo "$nfqws2_opt_section" >> "$config_file"

    # Добавить остальные настройки
    cat >> "$config_file" <<'CONFIG'

# ==============================================================================
# FIREWALL SETTINGS
# ==============================================================================

# Queue number for NFQUEUE
QNUM=200

# Firewall mark for desync prevention
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000

# Apply firewall rules in init script
INIT_APPLY_FW=1

# Flow offloading mode: none, software, hardware, donttouch
# Set during installation based on system detection
CONFIG
    # FLOWOFFLOAD must carry the value computed above, not the literal text —
    # the heredocs around it are single-quoted (literal), so emit it separately.
    echo "FLOWOFFLOAD=$flowoffload_value" >> "$config_file"
    cat >> "$config_file" <<'CONFIG'

# WAN interface override (space/comma separated). Empty = auto-detect
#WAN_IFACE=

# ==============================================================================
# SYSTEM SETTINGS
# ==============================================================================

# Temporary directory for downloads and processing
# Empty = use system default /tmp (tmpfs, in RAM)
# Set to disk path for low RAM systems (e.g., /opt/zapret2/tmp)
CONFIG
    # Добавить TMPDIR только если установлен
    if [ -n "$tmpdir_value" ]; then
        echo "TMPDIR=$tmpdir_value" >> "$config_file"
    else
        echo "#TMPDIR=/opt/zapret2/tmp" >> "$config_file"
    fi

    # Disable IPv6 processing (0=enabled, 1=disabled)
    # Auto-detected during install; can be overridden by setting DISABLE_IPV6 in environment/config.
    echo "" >> "$config_file"
    echo "# Disable IPv6 processing (0=enabled, 1=disabled)" >> "$config_file"
    echo "DISABLE_IPV6=$disable_ipv6_value" >> "$config_file"

    cat >> "$config_file" <<'CONFIG'

# ==============================================================================
# IPSET SETTINGS
# ==============================================================================

# Maximum elements in ipsets
SET_MAXELEM=522288

# ipset options
IPSET_OPT="hashsize 262144 maxelem $SET_MAXELEM"

# ip2net options
IP2NET_OPT4="--prefix-length=22-30 --v4-threshold=3/4"
IP2NET_OPT6="--prefix-length=56-64 --v6-threshold=5"

# Пороги автохостлиста живут выше, рядом с MODE_FILTER (секция с подстановкой):
# этот heredoc в одинарных кавычках и сохранённые значения сюда не подставить.

# ==============================================================================
# CUSTOM SCRIPTS
# ==============================================================================

# Directory for custom scripts
CUSTOM_DIR="/opt/zapret2/init.d/keenetic"
# DISABLE_CUSTOM is emitted in the variable-expanding section below (with the
# other saved_* flags) so the user's choice survives config regeneration —
# do NOT hardcode it here (this heredoc is single-quoted, no expansion).

# ==============================================================================
# MISCELLANEOUS
# ==============================================================================

# Temporary directory (if /tmp is too small)
#TMPDIR=/opt/zapret2/tmp

# User for zapret daemons (security hardening: drop privileges to nobody)
WS_USER=nobody

# Compress large lists
GZIP_LISTS=1

# Number of parallel threads for domain resolves
MDIG_THREADS=30

# EAI_AGAIN retries
MDIG_EAGAIN=10
MDIG_EAGAIN_DELAY=500
CONFIG

    # ОДИНАРНЫЕ КАВЫЧКИ ДЛЯ ЗНАЧЕНИЙ, КОТОРЫЕ ПИШЕТ ЧЕЛОВЕК.
    #
    # Конфиг не читается — он ИСПОЛНЯЕТСЯ: S99zapret2.new сорсит его через точку
    # от root. Имя политики Keenetic человек задаёт сам, произвольным текстом, и
    # оно проходит полный круг: меню/вебпанель → конфиг → safe_config_read →
    # снова конфиг при каждой регенерации. Двойные кавычки, поставленные здесь
    # ради пробелов и кириллицы, от разбиения на слова спасают, но подстановку
    # не запрещают: `$(...)`, обратные кавычки и `$VAR` внутри значения
    # выполнятся при следующем сорсинге с правами root. Одинарные кавычки не
    # раскрывают ничего вообще, а единственный символ, который в них не живёт —
    # сама одинарная кавычка — экранируется приёмом '\'' ниже.
    #
    # Это не гипотеза про злоумышленника: достаточно апострофа в имени вроде
    # «Vasya's network», чтобы конфиг перестал сорситься и сервис не поднялся.
    _pn_q=$(printf '%s' "$saved_POLICY_NAME" | sed "s/'/'\\\\''/g")
    _pe_q=$(printf '%s' "$saved_POLICY_EXCLUDE" | sed "s/'/'\\\\''/g")

    # Append settings that need variable expansion (heredoc with quotes doesn't expand)
    # База для ночного обновления списков доменов. Это ПОСТОЯННОЕ значение, а не
    # источник текущего прогона: z2k-update-lists.sh читает его из конфига по
    # расписанию, годами.
    #
    # Обновление на время своей работы пинит GITHUB_RAW на НЕИЗМЕНЯЕМЫЙ тег
    # релиза, чтобы всё приехало из одного среза. Раньше этот пин утекал сюда и
    # застывал в конфиге: роутер, переустановившийся на r-79.7, потом вечно
    # тянул списки из тега r-79.7 — ветка уезжала, а у него списки замирали, и
    # ни в одном логе это не выглядело ошибкой. С переходом на адресные
    # обновления переустановки стали редкими, то есть пин жил бы дольше.
    #
    # Поэтому пин срезаем: в конфиг идёт ветка, из которой роутер живёт.
    _z2k_persist_raw="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"
    case "$_z2k_persist_raw" in
        */necronicle/z2k/z2k-enhanced|*/necronicle/z2k/z2k-staging) ;;
        */necronicle/z2k/*)
            _z2k_persist_raw="${Z2K_RELEASE_BRANCH:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}" ;;
    esac

    cat >> "$config_file" <<EOF

# Game WARP mode — route game-server ipset through Cloudflare WARP (usque/MASQUE);
# engine is z2k-warp.sh. Toggled from the webpanel / menu [E].
GAME_WARP_ENABLED=${saved_GAME_WARP_ENABLED}

# Telegram tunnel: user-disable flag from menu/webpanel "Stop tunnel".
# Preserved across reinstall так что step_finalize autostart не воскрешал
# daemon, который юзер явно остановил.
TG_PROXY_USER_DISABLED=${saved_TG_PROXY_USER_DISABLED}

# Mid-stream stall detector bundle (default 1 per Mark 2026-05-02
# policy: все нововведения по умолчанию включены). At 1: rkn_tcp swaps
# failure_detector to z2k_mid_stream_stall, --in-range to -s20000, AND
# NFQWS2_TCP_PKT_IN bumps to 30 — all three move atomically. =0 для
# отката. Persisted here so a user-set value survives
# create_official_config regen.
Z2K_USE_MID_STREAM_DETECTOR=${saved_Z2K_USE_MID_STREAM_DETECTOR}

# TLS extension auto-injection master switch (default 0, 2026-05-03):
# выключено по дефолту после field-проверки — auto-injection
# z2k_grease/alpn/psk/keyshare/earlydata/pha/sct/delegcred/padencap к
# fake-стратегиям ломала handshake на cloudflare и большинстве хостов
# до r2 fix, после r2 даёт слабую JA3-distortion которой autocircular
# не выбирает. =1 для opt-in возврата автоинъекции (вместе с
# Z2K_PADENCAP=1 для управления padencap).
Z2K_INJECT_TLS_MODS=${saved_Z2K_INJECT_TLS_MODS}

# Dynamic TTL fool hook auto-inject (default 1). =0 для опт-аута на
# сетапах с принудительным NDM TTL-fix (команда "ip ttl-fix" на Keenetic при
# модемном тарифе с запретом раздачи: телефонная симка + IMEI-
# маскировка). В такой топологии NDM всё равно перебивает TTL всех
# исходящих, поэтому inject избыточен; опт-аут оставляет fake'ам
# default TTL стека и убирает per-fake lua call overhead на слабом MIPS.
Z2K_DYNAMIC_TTL=${saved_Z2K_DYNAMIC_TTL}

# Статические ip host для Instagram (обход DNS-отравления). 0 — юзер убрал их
# через меню [I]; установка и ежедневный рефреш их тогда не возвращают
# (issue #39). Переживает реинсталл. «Вернуть» в [I] ставит 1.
Z2K_INSTA_DNS=${saved_Z2K_INSTA_DNS}

# Anonymous strategy telemetry to the project VPS (default 1=ON). The uploader
# (z2k-stats-upload.sh, daily via z2k-scheduler) sends ONLY {pool, strategy,
# dwell} per rotation slot — never the visited host/domain, never your IP /
# provider / region, and no device identifier. Set =0 (menu/webpanel toggle) to
# opt out. Does not affect NFQWS2_OPT / the bypass itself.
Z2K_STATS=${saved_Z2K_STATS}

# Видел ли человек, какие поля уходят. 0 = ещё нет, первая отправка ждёт;
# 1 = экран показан (меню [C] или карточка в вебпанели) либо установка старая.
Z2K_STATS_ACK=${saved_Z2K_STATS_ACK}

# Custom.d scripts (50-stun4all / 50-discord-media — STUN desync that fixes
# WhatsApp/Telegram voice on some networks). Default 1 = disabled (z2k's own
# Discord strategy covers most cases). Enable via menu [S] / webpanel toggle
# (sets 0). Emitted here (expanding heredoc) with the preserved value so a regen
# from another toggle or auto-update no longer silently re-disables custom.d.
DISABLE_CUSTOM=${saved_DISABLE_CUSTOM}

# TLS padding extension flag — действует только когда
# Z2K_INJECT_TLS_MODS=1. Управляет добавлением padencap в дополнение
# к z2k_grease/alpn/psk/keyshare/earlydata/pha/sct/delegcred. =0 для
# отката padencap при включённой остальной инъекции.
Z2K_PADENCAP=${saved_Z2K_PADENCAP}

# Форма записи профилей в NFQWS2_OPT. =1 — общий арсенал объявляется один раз
# (--template) и подставляется в профили (--import); строка короче на 13 КБ, а
# правка арсенала физически не может разъехаться между профилями. =0 — прежняя
# плоская запись, где каждый профиль несёт свою полную копию. Аварийный
# выключатель: на поведение движка не влияет (проверено дампом профилей —
# идентичны), но если формат чем-то помешает, откат не требует нового релиза.
Z2K_NFQWS2_TEMPLATES=${saved_Z2K_NFQWS2_TEMPLATES}

# Keenetic policy integration (см. S99zapret2.new). POLICY_NAME — имя политики
# в админке Keenetic, POLICY_EXCLUDE — режим:
#   0 — обрабатывать ТОЛЬКО устройства из этой политики (default — политики
#       нет, NFQUEUE-rules применяются к всему трафику фактически)
#   1 — исключить устройства из этой политики из обработки z2k (нужно если
#       одно устройство должно ходить direct без модификации пакетов)
# preserve через reinstall (без префикса Z2K_, поэтому добавлены в whitelist).
# В ОДИНАРНЫХ КАВЫЧКАХ. Конфиг исполняется как скрипт (files/S99zapret2.new:197
# сорсит его через точку от root), а имя политики Keenetic человек задаёт сам и
# по-русски: «Через ВПН», «Прямой канал». Без кавычек такое присваивание
# разваливается на POLICY_NAME=Через и попытку выполнить ВПН как команду.
# Двойные кавычки, стоявшие здесь раньше, чинили только это, но оставляли
# работающими подстановку команд, обратные кавычки и подстановку переменных —
# при следующем сорсинге они исполнились бы от root. Одинарные не раскрывают
# ничего; экранирование самой кавычки сделано выше, при вычислении _pn_q/_pe_q.
# (Этот комментарий уезжает в сам конфиг, поэтому написан без знака доллара:
# внутри heredoc он раскрылся бы прямо при генерации.)
# Отчёт 2026-08-05: «нельзя прописать политику кириллицей и с пробелом».
POLICY_NAME='${_pn_q}'
POLICY_EXCLUDE='${_pe_q}'

# Keenetic per-flow hardware-offload exclusion (PPE de-offload). Default 1=ON.
# Webpanel toggle (toggle_ppe) sets Z2K_PPE_DEOFFLOAD=0; emitted here with the
# preserved value so a regen (the toggle's own regenerate_config, another toggle,
# or an auto-update reinstall) no longer wipes the key and lets the NDM hook
# silently re-enable de-offload after the user turned it off.
Z2K_PPE_DEOFFLOAD=${saved_Z2K_PPE_DEOFFLOAD}
Z2K_PPE_DEOFFLOAD_QUIC=${saved_Z2K_PPE_DEOFFLOAD_QUIC}
Z2K_PANEL_AUTH=${saved_Z2K_PANEL_AUTH}
Z2K_AUTO_UPDATE_ENABLED=${saved_Z2K_AUTO_UPDATE_ENABLED}

# Persist the branch URL that this install was booted from, so that
# z2k-update-lists.sh and other post-install tools (cron-driven) can
# continue pulling from the SAME branch instead of defaulting back to
# master. Set automatically from \$GITHUB_RAW at install time; edit by
# hand only if you know what you are doing.
Z2K_GITHUB_RAW="${_z2k_persist_raw}"
EOF

    # Записалось ли всё до конца. Хвост heredoc'а — последнее, что попадает в
    # файл, поэтому его наличие и есть признак «конфиг не обрезан».
    if [ ! -s "$config_file" ] || ! grep -q '^Z2K_GITHUB_RAW=' "$config_file"; then
        print_error "Конфиг записан не полностью — боевой файл оставлен прежним"
        rm -f "$config_file"
        config_file="$_cfg_target"
        return 1
    fi

    # Подмена одним rename: на той же ФС это атомарно, и сорсящий init-скрипт
    # видит либо старый конфиг целиком, либо новый целиком, но не половину.
    if ! mv -f "$config_file" "$_cfg_target"; then
        print_error "Не удалось заменить конфиг — боевой файл оставлен прежним"
        rm -f "$config_file"
        config_file="$_cfg_target"
        return 1
    fi
    config_file="$_cfg_target"

    print_success "Config файл создан: $config_file"
    return 0
}

# ==============================================================================
# ОБНОВЛЕНИЕ NFQWS2_OPT В СУЩЕСТВУЮЩЕМ CONFIG
# ==============================================================================

update_nfqws2_opt_in_config() {
    # Обновляет только секцию NFQWS2_OPT в существующем config файле
    # $1 - путь к config файлу

    local config_file="${1:-/opt/zapret2/config}"

    if [ ! -f "$config_file" ]; then
        print_error "Config файл не найден: $config_file"
        return 1
    fi

    print_info "Обновление NFQWS2_OPT в: $config_file"

    # Создать backup. Проверяем: страховка, которая молча не создалась, хуже
    # отсутствия страховки — на неё рассчитывают дальше по цепочке.
    if ! cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"; then
        print_error "Не удалось создать резервную копию конфига — правку не делаем"
        return 1
    fi

    # Генерировать новый NFQWS2_OPT (см. коммент в create_official_config:
    # порченый Strategy.txt роняет генерацию, старый конфиг не переписываем).
    local nfqws2_opt_section
    nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies) || return 1

    # Создать временный файл
    local temp_file="${config_file}.tmp"

    # Удалить старый NFQWS2_OPT и добавить новый
    awk '
    /^NFQWS2_OPT=/ {
        in_nfqws_opt=1
        next
    }
    in_nfqws_opt && /^"$/ {
        in_nfqws_opt=0
        next
    }
    !in_nfqws_opt { print }
    ' "$config_file" > "$temp_file" || {
        print_error "Не удалось подготовить новый конфиг (обрыв записи)"
        rm -f "$temp_file"
        return 1
    }

    # Добавить новый NFQWS2_OPT в конец файла (перед последней секцией)
    # Найти позицию для вставки (перед FIREWALL SETTINGS или в конец)
    #
    # Каждый шаг проверяется. Раньше ни awk, ни оба mv статус не отдавали, и
    # обрыв записи (полный или умирающий NAND — прецедент с 0xFF-мусором в
    # Strategy.txt был) укладывал усечённый конфиг поверх рабочего, а функция
    # печатала «NFQWS2_OPT обновлён» и возвращала 0. Конфиг сорсится root-овым
    # init-скриптом, так что полуфайл — это не косметика.
    if grep -q "# FIREWALL SETTINGS" "$temp_file"; then
        # Вставить перед FIREWALL SETTINGS
        if ! awk -v opt="$nfqws2_opt_section" '
        /# FIREWALL SETTINGS/ {
            print opt
            print ""
        }
        { print }
        ' "$temp_file" > "${temp_file}.2"; then
            print_error "Не удалось вставить NFQWS2_OPT (обрыв записи)"
            rm -f "$temp_file" "${temp_file}.2"
            return 1
        fi
        if ! mv "${temp_file}.2" "$temp_file"; then
            print_error "Не удалось подготовить конфиг к замене"
            rm -f "$temp_file" "${temp_file}.2"
            return 1
        fi
    else
        # Добавить в конец
        if ! { echo "" >> "$temp_file" && echo "$nfqws2_opt_section" >> "$temp_file"; }; then
            print_error "Не удалось дописать NFQWS2_OPT (обрыв записи)"
            rm -f "$temp_file"
            return 1
        fi
    fi

    # Заменить оригинальный файл
    if ! mv "$temp_file" "$config_file"; then
        print_error "Не удалось заменить конфиг — оставлен прежний, рабочий"
        rm -f "$temp_file"
        return 1
    fi

    print_success "NFQWS2_OPT обновлён в config файле"
    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Функции доступны после source этого файла
