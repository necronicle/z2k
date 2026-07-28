#!/bin/sh
# tests/test_panel_sort.sh
#
# Sorting the state table was implemented once, in the column headers. The
# mobile breakpoint hides the whole thead (style.css: `.state-table thead
# { display: none }`) and turns rows into cards — so on a phone the only sort
# control there was simply did not exist. This covers the mobile control that
# replaces it, and the persistence of the choice.
#
# Two things are worth pinning beyond "the code is there":
#
#   * The sortable keys are declared ONCE (STATE_SORT_LABELS) and consumed by
#     both the desktop headers and the sheet. Two lists would drift, and the
#     drift is invisible until someone on a phone cannot sort by a column the
#     desktop offers.
#   * A stored value must be VALIDATED on read. A stale key (column renamed in
#     a later release) would otherwise leave the table sorted by nothing, which
#     looks like a broken load rather than a stale setting — and the user has no
#     way to guess that clearing site data fixes it.
#
# The logic assertions run under node when it is available and are skipped
# otherwise; the structural ones always run. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
JS="$HERE/webpanel/www/app.js"
CSS="$HERE/webpanel/www/style.css"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/psort.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

[ -f "$JS" ] && [ -f "$CSS" ] || { printf '[FAIL] missing panel sources\n'; exit 1; }

# --- the control exists, and only where it is needed -------------------------
grep -q 'id="state-sort-btn"' "$JS" \
    && ok "кнопка сортировки рисуется над таблицей" \
    || no "кнопка сортировки рисуется над таблицей" "state-sort-btn" "нет"

# Desktop must be untouched: the trigger is display:none by default and only
# becomes visible inside the mobile breakpoint.
base=$(awk '/^\.sort-trigger \{/,/^\}/' "$CSS")
case "$base" in
    *"display: none;"*) ok "на десктопе кнопки нет (display:none по умолчанию)" ;;
    *) no "на десктопе кнопки нет" "display: none" "иначе" ;;
esac
# The rule that shows it must live inside a max-width media query, not at top level.
mob_line=$(grep -n '\.sort-trigger { display: inline-flex' "$CSS" | head -1 | cut -d: -f1)
if [ -n "$mob_line" ]; then
    guard=$(awk -v n="$mob_line" 'NR<n && /^@media/{last=$0} END{print last}' "$CSS")
    case "$guard" in
        *max-width*) ok "кнопка показывается только на мобильном брейкпоинте" ;;
        *) no "кнопка показывается только на мобильном" "@media max-width" "$guard" ;;
    esac
else
    no "правило показа кнопки существует" "display: inline-flex" "нет"
fi
# And it must be shown by the SAME breakpoint that hides the headers, or there
# is a width where neither control is available.
hide_line=$(grep -n '\.state-table thead { display: none' "$CSS" | head -1 | cut -d: -f1)
if [ -n "$mob_line" ] && [ -n "$hide_line" ]; then
    g1=$(awk -v n="$mob_line" 'NR<n && /^@media/{last=NR} END{print last}' "$CSS")
    g2=$(awk -v n="$hide_line" 'NR<n && /^@media/{last=NR} END{print last}' "$CSS")
    [ "$g1" = "$g2" ] \
        && ok "кнопка и скрытие заголовков — в одном и том же медиазапросе" \
        || no "кнопка и скрытие заголовков в одном медиазапросе" "один @media" "$g1/$g2"
fi

# --- dismissal, per NN/g -----------------------------------------------------
sheet=$(awk '/---------- Sort sheet \(mobile\)/,/---------- Boot/' "$JS")
case "$sheet" in
    *'id="sort-sheet-close"'*) ok "у шторки есть видимая кнопка закрытия" ;;
    *) no "у шторки есть видимая кнопка закрытия" "sort-sheet-close" "нет" ;;
esac
case "$sheet" in
    *'sort-sheet-backdrop").addEventListener("click", closeSortSheet)'*)
        ok "закрытие по тапу в затемнение" ;;
    *) no "закрытие по тапу в затемнение" "обработчик на backdrop" "нет" ;;
esac
case "$sheet" in
    *'e.key === "Escape"'*) ok "закрытие по Escape/Back" ;;
    *) no "закрытие по Escape/Back" "обработчик Escape" "нет" ;;
esac
case "$sheet" in
    *'aria-modal="true"'*) ok "шторка объявлена диалогом для скринридера" ;;
    *) no "шторка объявлена диалогом" "aria-modal" "нет" ;;
esac

# --- one source of truth for the sortable keys -------------------------------
grep -q 'const STATE_SORT_LABELS' "$JS" \
    && ok "ключи сортировки объявлены одним списком" \
    || no "ключи сортировки объявлены одним списком" "STATE_SORT_LABELS" "нет"
# The sheet must derive its options from that list, not hardcode its own.
case "$sheet" in
    *'Object.keys(STATE_SORT_LABELS)'*) ok "шторка берёт пункты из общего списка" ;;
    *) no "шторка берёт пункты из общего списка" "Object.keys(STATE_SORT_LABELS)" "свой список" ;;
esac
# Every key the comparator understands must be offered by the sheet, or a phone
# cannot reach a column the desktop can.
cmp_keys=$(awk '/const sorted = entries.slice\(\).sort/,/^      \}\);/' "$JS" \
           | sed -n 's/.*case "\([a-z]*\)":.*/\1/p' | LC_ALL=C sort | tr '\n' ',')
lbl_keys=$(sed -n 's/.*const STATE_SORT_LABELS = { \(.*\) };/\1/p' "$JS" \
           | tr ',' '\n' | sed -n 's/^[[:space:]]*\([a-z]*\):.*/\1/p' | LC_ALL=C sort | tr '\n' ',')
[ -n "$cmp_keys" ] && [ "$cmp_keys" = "$lbl_keys" ] \
    && ok "набор ключей совпадает с тем, что умеет сортировщик ($cmp_keys)" \
    || no "набор ключей совпадает с сортировщиком" "$cmp_keys" "$lbl_keys"

# --- direction semantics match the desktop -----------------------------------
# Second tap flips, a new key starts asc except the numeric column.
case "$sheet" in
    *'stateSort.dir = stateSort.dir === "asc" ? "desc" : "asc"'*)
        ok "повторный тап переворачивает направление" ;;
    *) no "повторный тап переворачивает направление" "флип dir" "нет" ;;
esac
case "$sheet" in
    *'(key === "strategy") ? "desc" : "asc"'*)
        ok "умолчание направления как у десктопных заголовков" ;;
    *) no "умолчание направления как у заголовков" "strategy -> desc" "иначе" ;;
esac

# --- persistence -------------------------------------------------------------
grep -q '"z2k-state-sort"' "$JS" \
    && ok "выбор хранится под собственным ключом" \
    || no "выбор хранится под собственным ключом" "z2k-state-sort" "нет"
# Both controls must persist, or the choice survives from one and not the other.
hdr=$(awk '/querySelectorAll\("th.sortable"\)/,/^      \}\);/' "$JS")
case "$hdr" in
    *saveStateSort*) ok "клик по заголовку сохраняет выбор" ;;
    *) no "клик по заголовку сохраняет выбор" "saveStateSort()" "нет" ;;
esac
case "$sheet" in
    *saveStateSort*) ok "выбор в шторке сохраняется" ;;
    *) no "выбор в шторке сохраняется" "saveStateSort()" "нет" ;;
esac
# Storage may be unavailable (private mode, disabled): it must never throw.
case "$(awk '/function loadStateSort/,/^  \}/' "$JS")" in
    *'catch (_)'*) ok "недоступное хранилище не роняет панель" ;;
    *) no "недоступное хранилище не роняет панель" "try/catch" "нет" ;;
esac

# --- validation on read, behaviourally ---------------------------------------
if command -v node >/dev/null 2>&1; then
    # STATE_SORT_KEY too, not just the labels: without it the function throws a
    # ReferenceError, its own try/catch swallows that, and EVERY case returns the
    # fallback — so the fallback assertions pass while proving nothing.
    awk '/const STATE_SORT_KEY/{print} /const STATE_SORT_LABELS/{print} /function loadStateSort/,/^  \}/{print}' "$JS" \
        | sed 's/^  //' > "$TMP/fn.js"
    cat >> "$TMP/fn.js" <<'JS'
let store = null;
globalThis.localStorage = { getItem: () => store };
const t = (raw, wantKey, wantDir, label) => {
  store = raw;
  const v = loadStateSort();
  const okk = v.key === wantKey && v.dir === wantDir;
  console.log((okk ? "OK " : "BAD ") + label + " -> " + JSON.stringify(v));
};
t(null,                              "key",  "asc",  "nothing stored");
t('{"key":"host","dir":"desc"}',     "host", "desc", "valid value round-trips");
t('{"key":"нет-такого","dir":"asc"}',"key",  "asc",  "unknown key falls back");
t('{"key":"host","dir":"sideways"}', "key",  "asc",  "bad direction falls back");
t('not json at all',                 "key",  "asc",  "corrupt json falls back");
t('null',                            "key",  "asc",  "literal null falls back");
JS
    out=$(node "$TMP/fn.js" 2>&1)
    n_bad=$(printf '%s\n' "$out" | grep -c '^BAD' || true)
    n_ok=$(printf '%s\n' "$out" | grep -c '^OK' || true)
    if [ "$n_bad" = 0 ] && [ "$n_ok" -ge 6 ]; then
        ok "чтение сохранённого значения проверяется ($n_ok случаев)"
    else
        no "чтение сохранённого значения проверяется" "0 плохих" "$(printf '%s' "$out" | tr '\n' ' ')"
    fi
else
    skip "поведенческая проверка валидации" "нет node; структурные проверки выше отработали"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
