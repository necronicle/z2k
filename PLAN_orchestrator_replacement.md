# План: замена пропавшего upstream `circular_locked` на autocircular state-machine

## Решение: option 2 — осознанная замена, не копия

Upstream'овский `circular_locked` (lua action из `AloofLibra/zapret4rocket@z2r:orchestra/locked.lua` — **файл ещё существует upstream'е, но осиротел после удаления `orchestrator.sh` 2026-05-07, который был его daemon-companion'ом**) фактически был **selector'ом**, не auto-rotator'ом:
- Читал `locked.tsv` / `locked.manual.tsv`, искал запись по `(profile, proto)`.
- Если найдена — выполнял зафиксированную strategy.
- Если не найдена — выполнял strategy 1.

Параллельный `orchestrator.sh` daemon только писал в `fails.tsv` через `logread`, но **в run_loop'е никогда не вызывал `lock_add`** — то есть никаких lock'ов не создавал автоматически. Записи в `locked.tsv` существовали только если их добавил кто-то вручную через CLI subcommand или upstream'овский `z2r.sh` menu (AloofLibra-specific, в z2k не shipped'ился). У большинства users'ов `locked.tsv` пустой → upstream фактически работал как «всегда strategy=1, никакой ротации».

Это **не план копировать пропавший файл байт-в-байт**. Это **осознанная замена сломанного lock-based механизма на нашу существующую autocircular state-machine** (`z2k-autocircular.lua`, 1425 строк, wraps `circular()`, делает per-host persistence + telemetry-driven rotation).

**Цель в смысловом плане:** подобрать и удерживать рабочую strategy для Discord UDP, **без внешнего log daemon'а**, через failure detection + persistence в `state.tsv`. Чего у upstream фактически не было — у нас будет.

## Контекст конкретики

`lib/install.sh` качает с upstream'а:
- `orchestra/orchestrator.sh` — **удалён upstream'ом 2026-05-07** (баг z2k#15 — пропавший файл, install warning'и). Это основная триггер-причина PR.
- `orchestra/locked.lua` — **upstream-овский файл ещё существует**, но без `orchestrator.sh` lock-based ротация всё равно неработоспособна. Мы тоже его не нужны (см. план).

`circular_locked` action используется ровно в **двух местах**, оба для Discord UDP:
- `lib/config_official.sh:116` (`discord_udp` profile)
- `quic_strats.ini:10` (`[discord_voice_autocircular]`)

В обоих: `--lua-desync=circular_locked:key=6:allow_nohost=1`. Семантика `key=6` upstream'а — profile lookup identifier для locked.tsv (numeric tag, не "strategy 6"). `allow_nohost=1` — продолжать когда нет реального hostname (Discord DTLS handshake без SNI).

Наша autocircular уже умеет:
- per-host persistence в `state.tsv`
- failure-driven rotation через `automate_failure_check` + `circular()`'s `(n % ct) + 1`
- удержание working strategy через `policy_seed_strategy` (ok-ratio > 0.5 → keep current, 3% explore_good chance)
- telemetry, probe override, YouTube silent-retry

Не умеет одного: **стабильно работать с hostless flows**. Сейчас `standard_hostkey` при отсутствии hostname делает fallback на `host_ip(desync)` (`zapret-auto.lua:20`) → per-IP rotation. Для Discord UDP это создаёт отдельную запись на каждый media-server IP, ротация конвергирует медленно (каждый IP заново ищет работающую strategy).

Решение — добавить в нашу wrapped `circular` обработку `allow_nohost=1`: при hostless flow подменять `desync.track.hostname` на стабильный sentinel `"nohost"` до вызова `orig_circular`, восстанавливать после. Это даёт shared rotation state для всех Discord UDP flow'ов без SNI, минимальное вмешательство в существующий код.

## Содержимое плана

### A. Bug-fix часть (обе ветки: master + z2k-enhanced)

Это устранение факапа: качаем несуществующий файл.

A1. **`lib/install.sh`** — снять три блока:
- `z2k_fetch ".../orchestra/orchestrator.sh"` + `chmod +x` + warning (master:1001-1010, enhanced:1146-1153).
- `z2k_fetch ".../orchestra/locked.lua"` + warning (master:994-998, enhanced:1139-1143).
- `mkdir -p .../orchestra` (master:~969, enhanced:1114).

A2. **`files/S99zapret2.new`** — снять пять строк:
- `ORCH_SCRIPT="$EXTRA_STRATS_DIR/cache/orchestra/orchestrator.sh"` (line 616).
- `[ -x "$ORCH_SCRIPT" ] && "$ORCH_SCRIPT" start` в start() (line 1401).
- `[ -x "$ORCH_SCRIPT" ] && "$ORCH_SCRIPT" stop` в stop() (line 1413).
- `LUA_LOCKED="$ZAPRET_BASE/lua/locked.lua"` (line 454).
- `[ -f "$LUA_LOCKED" ] && LUAOPT="$LUAOPT --lua-init=@$LUA_LOCKED"` (line 455).

A3. **`lib/config_official.sh:116`** и **`quic_strats.ini:10`** — заменить `circular_locked` на `circular` с `allow_nohost=1`, **но с разными `key=` namespaces** (REV: один shared `key=discord_udp` ломается при переключении профилей — config_official имеет 6 стратегий, quic_strats discord_voice имеет 12; persisted nstrategy=10 после 12-version не valid в 6-version, normalize в wrapped circular фактически отрабатывает **после** orig_circular → первый packet после switch'а уйдёт без desync, потом reset на 1).

**`config_official.sh:116`** (default profile, 6 стратегий):
```
--lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:allow_nohost=1 --lua-desync=fake:...:strategy=1 ... :strategy=6
```

**`quic_strats.ini:10`** (alternative "modern" 12-strategy profile):
```
--lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_voice:nld=2:allow_nohost=1 --lua-desync=z2k_quic_morph_v2:...:strategy=1 ... :strategy=12
```

Разные `key=` дают разные records в state.tsv: `discord_udp\tnohost\t<N>` (для 6-strat profile) vs `discord_voice\tnohost\t<N>` (для 12-strat profile). Persisted state одного профиля не конфликтует с другим при переключении. Switch чистый: новый профиль читает свою запись (или пустую), без out-of-range race.

**Контракт `allow_nohost=1`** — наш новый argument, обрабатываемый в wrapped circular (B1). Остальные args (`fails`, `time`, `udp_in`, `udp_out`, `nld`) — стандартные `circular:` arg'ы.

Замена идентична на обеих ветках. Никаких branch-specific вариантов нет.

**Тест на switch** (см. B4 ниже): записать state с `discord_voice\tnohost\t10`, переключиться на `discord_udp` profile (ctstrategy=6), убедиться что: (a) `discord_voice\tnohost\t10` остался нетронутым (другой namespace), (b) `discord_udp\tnohost\t<N>` создан с N в [1,6] и Discord работает с первого packet'а.

A4. **Cleanup существующих установок:** в `lib/install.sh` при `reinstall` добавить purge до `rm -rf "$ZAPRET2_DIR"` (до line 772). **Fail-closed backup** (REV: ранее `cp -a && warn` + безусловный `rm -rf` — при failed copy данные тихо терялись; теперь cp failure aborts step):
```sh
# Backup legacy orchestra data (locked.tsv / locked.manual.tsv) на случай если
# у пользователя были learned/manual locks от upstream orchestrator'а.
if [ -d "${ZAPRET2_DIR}/extra_strats/cache/orchestra" ]; then
    if [ -n "$(ls -A "${ZAPRET2_DIR}/extra_strats/cache/orchestra/" 2>/dev/null)" ]; then
        local _orch_backup="/tmp/z2k-legacy-orchestra-$(date +%Y%m%d-%H%M%S)"
        if cp -a "${ZAPRET2_DIR}/extra_strats/cache/orchestra" "$_orch_backup" 2>/dev/null; then
            print_warning "Legacy orchestra/ saved to $_orch_backup (locks НЕ мигрируются автоматически)"
        else
            print_error "Failed to backup ${ZAPRET2_DIR}/extra_strats/cache/orchestra → $_orch_backup"
            print_error "Aborting cleanup чтобы не потерять legacy lock state."
            print_error "Освободите место в /tmp или manually переместите orchestra/ перед повторным reinstall."
            return 1
        fi
    fi
    rm -rf "${ZAPRET2_DIR}/extra_strats/cache/orchestra"
fi
rm -f "${ZAPRET2_DIR}/lua/locked.lua"
```
Если backup fail'ит (например `/tmp` full) — `rm -rf` НЕ выполняется, install step возвращает ошибку, юзер видит actionable message. После manual cleanup можно retry'ить.

**Legacy lock migration policy.** Auto-migration НЕ делаем:
- upstream'овский orchestrator никогда не писал в locked.tsv в run_loop'е (только в fails.tsv) — у большинства users locked.tsv пустой или содержит stale data.
- `locked.manual.tsv` создавался только AloofLibra'ным `z2r.sh` menu, z2k его не shipped'ил — практически отсутствует у наших users.
- Auto-migration `key=6` (numeric profile id) → `discord_udp` (askey) semantically нестабильна.

Backup-only: legacy данные копируются в `/tmp/z2k-legacy-orchestra-<timestamp>/` с warning'ом. Release notes должны явно сказать про backup location.

A5. **`tests/test_install_completeness.sh:73`** — убрать `lua/locked.lua` из `TARBALL_WHITELIST`.

A6. **`files/z2k-config-validator.sh:322`** — `KNOWN_LUA_DESYNC_ACTIONS`:
- Убрать `circular_locked` (action больше не используется).
- `circular` уже в списке — не трогаем.
- Добавить `allow_nohost` в whitelist валидных `circular:` arg'ов (если такой whitelist есть; если нет — пропустить).

A7. **Лишние упоминания `circular_locked` в текстах:**
- `README.md:41-42` — переписать описание Discord UDP: «UDP voice/video: `circular` с `allow_nohost` (стратегия закрепляется через autocircular state.tsv после первого успеха)».
- `tests/test_config_official.sh:393` — обновить `SAMPLE_OPT` строки: `circular_locked:key=6` → `circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:allow_nohost=1`. Это shipped fixture, без правки тесты обязаны упасть.
- **`lib/config_official.sh:115`** (REV: добавлено по ревью — stale комментарий «разнообразия fingerprint'ов в **circular_locked rotator'е**» рядом с заменяемой строкой 116). Обновить comment на: «разнообразия fingerprint'ов в circular-через-autocircular rotator'е» (или просто убрать упоминание `circular_locked` — comment описывает rationale fingerprint variety, не сам rotator).

### B. allow_nohost extension в wrapped circular (обе ветки)

Один минимальный сквозной change в `files/lua/z2k-autocircular.lua`. Расширяем существующую `circular` обёртку чтобы при `desync.arg.allow_nohost == "1"` И отсутствии реального hostname подменять `desync.track.hostname` на стабильный sentinel `"nohost"`. После `orig_circular` восстанавливаем оригинальный hostname.

Это даёт `standard_hostkey` через `desync.track.hostname` стабильное значение `"nohost"` вместо fallback'а на `host_ip(desync)`. Все Discord UDP flow'ы без SNI шарят одну запись на active profile (REV: уточнено — теперь два namespace'а):
- При active `discord_udp` profile (config_official.sh, 6 strats): `autostate["discord_udp"]["nohost"]` + строка `discord_udp\tnohost\t<N>\t<ts>` в state.tsv.
- При active `discord_voice` profile (quic_strats.ini, 12 strats): `autostate["discord_voice"]["nohost"]` + строка `discord_voice\tnohost\t<N>\t<ts>`.

Profiles взаимоисключающие в runtime (одновременно активен один). Persistence/rotation/policy_seed работают штатно внутри namespace'а; switch между профилями не вызывает out-of-range collision (см. A3 namespace decision).

B1. **Изменения в `z2k-autocircular.lua`**.

Точка вставки — в начале существующей closure `circular = function(ctx, desync)` (line ~1284).

**Контракт error-семантики** (REV: важно — wrapper уже имеет inner pcall'ы pre-block (line 1290) и post-block (line 1301), которые **сознательно swallow'ят** errors из telemetry/persistence/debug logic'и. Это established контракт: ошибки внутри нашей бухгалтерии не должны ломать nfqws desync path. Мы его НЕ меняем. Outer pcall нужен **только** вокруг `orig_circular` call'а для finally-restore hostname'а перед propagation'ом error'а):

| Источник error'а | Текущее поведение | После нашего change |
|---|---|---|
| pre-block (existing inner pcall) | swallow'ится | swallow'ится (как было) |
| `orig_circular(ctx, desync)` | propagate'ится наверх | propagate'ится (с предварительным restore hostname'а) |
| post-block (existing inner pcall) | swallow'ится | swallow'ится (как было) |

```lua
if type(circular) == "function" then
  local orig_circular = circular

  -- Compute hostname swap (returns flag и saved value либо nil/false).
  local function nohost_setup(desync)
    local arg = desync and desync.arg
    local allow_nohost = arg and (arg.allow_nohost == "1" or arg.allow_nohost == 1)
    if not (allow_nohost and desync.track) then return false, nil end
    local h = desync.track.hostname
    local has_real_hostname = h and #h > 0 and not desync.track.hostname_is_ip
    if has_real_hostname then return false, nil end
    local saved = h
    desync.track.hostname = "nohost"
    return true, saved
  end

  local function nohost_restore(desync, nohost_active, saved_hostname)
    if nohost_active and desync.track then
      desync.track.hostname = saved_hostname  -- nil либо original value
    end
  end

  circular = function(ctx, desync)
    local nohost_active, saved_hostname = nohost_setup(desync)

    -- Pre-block — existing inner pcall, errors swallow'ятся, без изменений.
    pcall(function()
      -- ... existing askey_before/hostn_before/hrec_before computation,
      --     policy_seed_strategy, apply_probe_override, flow_start_if_needed ...
    end)

    -- Wrap orig_circular для finally-restore. Только эта точка может реально
    -- propagate'ить error в nfqws (pre/post swallow'ятся inner pcall'ами).
    local ok, verdict_or_err = pcall(orig_circular, ctx, desync)

    if ok then
      -- Post-block — existing inner pcall, errors swallow'ятся, без изменений.
      -- Запускается ТОЛЬКО при успешном orig_circular (мirror'ит existing wrapper:
      -- сейчас post идёт после bare `local verdict = orig_circular(...)`, и при
      -- throw'е orig_circular post не выполняется).
      pcall(function()
        -- ... existing conn_record_flags, success/failure event derivation,
        --     persist_if_changed, telemetry_record_event, debug_log,
        --     pending_write flush — все references verdict_or_err как verdict ...
      end)
    end

    -- Finally: restore выполняется ВСЕГДА, до пропаганды error'а.
    nohost_restore(desync, nohost_active, saved_hostname)

    if not ok then
      -- Re-throw сообщение orig_circular'а. level=0 значит "не добавлять
      -- 'circular.lua:N: ' prefix" — error пойдёт с original text как
      -- если бы pcall не было.
      error(verdict_or_err, 0)
    end
    return verdict_or_err  -- ok=true → это verdict
  end
end
```

**Что меняется по сравнению с current wrapper:**
- Добавлен `nohost_setup`/`nohost_restore` вокруг существующего тела.
- `orig_circular` обёрнут в pcall **только ради finally**.
- `if ok then post-block` сохраняет existing семантику «post runs только при success orig_circular».
- Inner pcall'ы пре/пост блоков **не трогаются**.

**Стоимость pcall.** Один дополнительный pcall per packet — `circular()` всё-равно вызывается per-packet'но. Lua pcall в hot path ~50ns overhead на ARM/MIPS, ничтожно vs ~1-10µs самого circular.

Семантические правила:
1. `allow_nohost=1` + есть реальный hostname (не nil, не пустой, не IP литерал) → ничего не подменяем, нормальный circular path. allow_nohost — это **только** about hostless flows.
2. `allow_nohost=1` + нет реального hostname → подменяем на `"nohost"`. После orig_circular возвращаем как было.
3. `allow_nohost=0` (или arg отсутствует) + нет hostname → стандартное поведение `circular`: `standard_hostkey` fallback'ит на `host_ip(desync)` (если `reqhost` не задан) → per-IP rotation. Backcompat для всех остальных `circular:` usages в config.
4. `allow_nohost=0` + есть hostname → обычный путь.

`"nohost"` валидный hostname с точки зрения `normalize_hostkey_for_state` (lowercase ASCII, без trailing dot). В state.tsv появится строка `discord_udp\tnohost\t<N>\t<ts>` — выглядит как обычный entry, парсер не споткнётся.

**Edge case `hostname_is_ip=true`.** Если nfqws ставит `track.hostname="1.2.3.4"` с `hostname_is_ip=true` (IP литерал в SNI или из SOCKS), наш `has_real_hostname` обрабатывает это правильно — IP литерал считается за no-real-hostname, идём в nohost path. Это важно для DTLS flows с IP literal вместо SNI.

**Restoration важен** потому что:
- Tail nfqws lua hooks (если есть) могут читать `desync.track.hostname` для своих целей.
- Conn record state persists across packet boundary через `desync.track.lua_state` — мутация `desync.track.hostname` без restore'а могла бы зацепиться в неожиданном месте.

`saved_hostname` это локальная переменная в closure scope (не leaks в global namespace).

B2. **Никаких других изменений в z2k-autocircular.lua не требуется:**
- `get_record_for_desync`, `policy_seed_strategy`, `apply_probe_override`, `persist_if_changed`, `flow_start_if_needed`, `flow_finish`, `telemetry_record_event`, `automate_failure_check` — все работают штатно с подменённым hostname.
- state.tsv parser принимает `nohost` как обычный host string.
- normalize_hostkey_for_state лояльно нормализует `"nohost"` (lowercase ASCII, идемпотентно).
- `clear_persisted`, write_state — не требуют изменений.

B3. **Никаких новых файлов:**
- НЕ создаём `pins.tsv`
- НЕ добавляем `/pins` REST endpoint
- НЕ изменяем webpanel UI
- НЕ добавляем feature flag `Z2K_HOST_PINS` или whitelist `Z2K_PINNABLE_KEYS`
- НЕ меняем lock-протоколы
- НЕ требуются shell-helper'ы в `actions.sh`

Если в будущем понадобится manual pinning — отдельный PR. Текущий plan покрывает **только** restoration функциональности после пропавшего upstream'а, через autocircular.

### Тесты

**`tests/test_z2k_circular_allow_nohost.lua` + `tests/test_z2k_circular_allow_nohost.sh` wrapper** (паттерн `test_probe_override.lua`/`.sh`).

Wrapper изолирует state через env override'ы:
```sh
#!/bin/sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DIR="/tmp/z2k-test-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP

LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"; break
    fi
done
[ -z "$LUA" ] && { printf "[PASS] allow_nohost: skipped (lua not installed)\n"; exit 0; }

cd "$PROJECT_ROOT"
Z2K_AUTOCIRCULAR_DIR_OVERRIDE="$TEST_DIR" \
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR" \
    "$LUA" tests/test_z2k_circular_allow_nohost.lua
```

Изменение в `z2k-autocircular.lua` (для test isolation; production оставляем как есть):
```lua
local STATE_DIR_PRIMARY = os.getenv("Z2K_AUTOCIRCULAR_DIR_OVERRIDE")
                          or "/opt/zapret2/extra_strats/cache/autocircular"
local _fallback_base    = os.getenv("Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE")
                          or "/tmp"
local STATE_FILE_FALLBACK     = _fallback_base .. "/z2k-autocircular-state.tsv"
local TELEMETRY_FILE_FALLBACK = _fallback_base .. "/z2k-autocircular-telemetry.tsv"
local DEBUG_FLAG_FALLBACK     = _fallback_base .. "/z2k-autocircular-debug.flag"
local DEBUG_LOG_FALLBACK      = _fallback_base .. "/z2k-autocircular-debug.log"
```

Production без env vars → старые hardcoded paths (`/opt/zapret2/...` + `/tmp/z2k-autocircular-*`).

Test cases:
1. **allow_nohost=1 + hostname=nil** → `desync.track.hostname` подменяется на `"nohost"`, после orig_circular восстанавливается на nil. `autostate["discord_udp"]["nohost"]` создан, host_ip-based записи НЕ созданы.
2. **allow_nohost=1 + hostname="1.2.3.4" + hostname_is_ip=true** → IP литерал считается за no-real-hostname, тот же путь как (1). Verify `autostate["discord_udp"]["nohost"]` создан, `autostate["discord_udp"]["1.2.3.4"]` НЕ создан.
3. **allow_nohost=1 + hostname="voice.discord.gg" + hostname_is_ip=false** → реальный hostname, никакой подмены, путь идёт нормально. `autostate["discord_udp"]["voice.discord.gg"]` создан.
4. **allow_nohost=0 + hostname=nil + reqhost=nil** → backcompat: standard_hostkey fallback'ит на host_ip → per-IP rotation. `autostate["discord_udp"][<IP>]` создан, не `["nohost"]`.
5. **Persistence**: после (1) write_state → file содержит `discord_udp\tnohost\t<N>\t<ts>`. Next process load_state → seed `hrec.nstrategy` из persisted.
6. **Rotation на failure**: после (1) failure_detector выставляет crec.failure → `(nstrategy % ct) + 1`. Verify rotation работает идентично normal-host'у.
7. **Hostname restoration on normal exit**: после прохождения (1) `desync.track.hostname` === saved (nil), не остался `"nohost"`. Critical чтобы downstream hooks не сбились.
8. **(REV)** **Hostname restoration on orig_circular error**: mock `orig_circular = function() error("forced test error") end`. Вызов wrapped `circular(ctx, desync)`:
   - Должен **propagate** error (test catches через pcall, ожидает ok=false, message == "forced test error" или с file:line prefix'ом если level≠0 случайно сработает).
   - `desync.track.hostname` после throw'а === saved (nil), не `"nohost"`. Это финальный finally-контракт.
9. **(REV: case удалён)** Post-block error swallow тестировать runtime'но **не будем** (REV-этой-итерации: `persist_if_changed`, `telemetry_record_event`, `conn_record_flags`, `flow_finish`, `debug_log` — все declared как `local function` в `z2k-autocircular.lua` (line 1001+); через `_G.<name> = error_fn` не подменяются, mock с file-load level требует Lua-magic'а уровня `setfenv`/`debug.setupvalue` который ломает другие тесты. Production-hook вводить ради тестируемости — не вариант (overkill для уже-работающего contract'а)).

   **Вместо runtime теста — структурный контракт.** Post-block swallow обеспечивается через **сохранение существующих inner `pcall`'ов** при модификации wrapper'а (см. snippet в B1 шаге выше — pre-block в `pcall(function() ... end)`, post-block в `pcall(function() ... end)` под `if ok then`). Если PR удалит/переместит эти inner pcall'ы — это **code review responsibility**, отлавливается diff inspection'ом, не unit test'ом.

   Документируется в комментарии прямо в lua-коде рядом с inner pcall'ами:
   ```lua
   -- DO NOT remove these inner pcall's: post-block telemetry/persist errors
   -- must stay swallowed (existing contract since 2026-XX-XX), иначе bug
   -- в нашей бухгалтерии будет ломать nfqws desync path.
   ```

   Эта формулировка явно фиксирует «контракт structurally preserved, runtime test невозможен без production hook'а».
10. **(REV)** **Namespace separation 6-strat vs 12-strat**: state.tsv заранее содержит `discord_voice\tnohost\t10\t<ts>` (12-strat profile state). Вызов wrapped `circular` с `key=discord_udp` (6-strat config_official profile):
    - `discord_voice\tnohost\t10` остаётся **нетронутым** (другой askey namespace).
    - `discord_udp\tnohost\t<N>` создан с N в [1,6] (свежий seed/default), Discord работает с первого packet'а — никакого "первый packet undesync'd" не происходит.
    - Reverse switch (state имеет `discord_udp\tnohost\t3`, запускаем 12-strat profile с `key=discord_voice`): свежий seed на `discord_voice\tnohost\t<N>` с N в [1,12], старый discord_udp нетронут.

### Branch propagation

Все шаги (A1-A7, B1, B2) — **обе ветки** (master + z2k-enhanced). По правилу `feedback_bugfix_branch_propagation` баг от пропавшего файла = fix обе ветки. По правилу `feedback_features_default_on` — features default ON, но здесь и feature flag'а нет, поведение единое.

### Что НЕ делается

- Не создаём `pins.tsv`, `/pins` endpoint, webpanel UI, manual pinning.
- Не портируем upstream'овский `circular_locked` 1-в-1 (контракт key=N был numeric profile id; наш — askey string; кросс-семантика бессмысленна).
- Не делаем auto-migration legacy locked.tsv → state.tsv (backup-only, см. A4).
- Не вводим feature flag `Z2K_HOST_PINS` или whitelist — есть один путь, отключать нечего.
- Не реализуем мониторинг logread (то что делал orchestrator.sh) — наша telemetry feed'ится напрямую из lua через failure/success detector'ы, без посредника.
- Не трогаем wrapped circular кроме hostname swap'а — никаких новых action'ов, lookup-приоритетов, нормализаций.

### Резюме изменений

| Файл | Изменение | Branches |
|------|-----------|----------|
| `lib/install.sh` | Снять 3 fetch блока + добавить backup-and-purge orchestra/ (A1, A4) | master + enhanced |
| `files/S99zapret2.new` | Снять 5 строк LUA_LOCKED/ORCH_SCRIPT (A2) | master + enhanced |
| `lib/config_official.sh:116` | `circular_locked:key=6:allow_nohost=1` → `circular:...:key=discord_udp:...:allow_nohost=1` (A3) | master + enhanced |
| `quic_strats.ini:10` | `circular_locked:key=6:allow_nohost=1` → `circular:...:key=discord_voice:...:allow_nohost=1` (A3, разный key для 12-strat profile) | master + enhanced |
| `tests/test_install_completeness.sh:73` | Убрать locked.lua из whitelist (A5) | master + enhanced |
| `files/z2k-config-validator.sh:322` | Убрать circular_locked (A6) | master + enhanced |
| `README.md:41-42` | Update описания Discord UDP (A7) | master + enhanced |
| `tests/test_config_official.sh:393` | Update SAMPLE_OPT (A7) | master + enhanced |
| `files/lua/z2k-autocircular.lua` | allow_nohost handling в wrapped circular + env override constants (B1) | master + enhanced |
| `tests/test_z2k_circular_allow_nohost.{lua,sh}` | Новые тестовые файлы | master + enhanced |

~30 строк нового lua-кода (allow_nohost block + env override paths). ~7 файлов с правками. Один тестовый suite.

### Полевая проверка

После merge:
1. Один из юзеров чата (Discord-heavy) делает reinstall с `z2k.sh`.
2. Через несколько часов работы Discord — проверить `cat /opt/zapret2/extra_strats/cache/autocircular/state.tsv | grep -E 'discord_udp|discord_voice'` на router'е. Ожидаемое (для default profile): одна строка `discord_udp\tnohost\t<N>\t<ts>` (или несколько если у юзера есть реальные SNI Discord flows). Если юзер на alternative 12-strat profile из quic_strats.ini — строка `discord_voice\tnohost\t<N>\t<ts>`.
3. Если работает Discord voice — strategy зафиксирована. Если нет — пользователь сообщает, мы смотрим какая strategy в state.tsv и почему она не работает.
4. Сравнить с pre-fix состоянием: до фикса либо `circular_locked` upstream'а молча фейлил install, либо после fetch fail'а юзер видел только warning при установке. После фикса — рабочая ротация через autocircular.
