#!/bin/sh
# scripts/rehearse_check_sha.sh МАНИФЕСТ — 0, если каждый файл из install_map
# лежит по своему адресу и его sha совпадает с files_sha256.
#
# ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ВНУТРИ ДВИЖКА. Это единственное место, где проверка
# «дерево равно манифесту» выражена целиком, и зовут её дважды: после успешного
# прохода и после отката. Две копии одной проверки разъедутся — и тогда зелёный
# после отката будет означать не то же самое, что зелёный после доставки.
#
# Адреса берутся из install_map как есть: в песочнице они указывают внутрь
# временного каталога, потому что фикстура их такими и записала.
#
# POSIX sh.
set -u
M="${1:-}"
[ -n "$M" ] && [ -f "$M" ] || { printf 'нет манифеста: %s\n' "$M" >&2; exit 2; }

TMP="${TMPDIR:-/tmp}/.rh-sha.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

# Один проход: цели и суммы в общий поток, различаются меткой первого поля.
awk '
    /"[^"]+"[[:space:]]*:[[:space:]]*\[/ {
        line = $0
        if (!match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\[/)) next
        rest = substr(line, RSTART + RLENGTH)
        key = substr(line, RSTART + 1); sub(/"[[:space:]]*:[[:space:]]*\[.*/, "", key)
        sub(/\].*/, "", rest)
        n = split(rest, parts, ",")
        for (i = 1; i <= n; i++) {
            t = parts[i]
            gsub(/^[[:space:]]*"/, "", t); gsub(/"[[:space:]]*$/, "", t)
            if (t ~ /^\//) print "MAP\t" key "\t" t
        }
        next
    }
    /"[^"]+"[[:space:]]*:[[:space:]]*"[0-9a-f][0-9a-f]*"/ {
        if (!match($0, /"[^"]+"[[:space:]]*:[[:space:]]*"[0-9a-f][0-9a-f]*"/)) next
        seg = substr($0, RSTART, RLENGTH)
        key = substr(seg, 2); sub(/"[[:space:]]*:.*/, "", key)
        val = seg; sub(/.*:[[:space:]]*"/, "", val); sub(/"$/, "", val)
        if (length(val) == 64) print "SHA\t" key "\t" val
    }
' "$M" > "$TMP" 2>/dev/null

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

rc=0
while IFS="$(printf '\t')" read -r kind key val; do
    [ "$kind" = "SHA" ] || continue
    # У пути может быть несколько целей (списки лежат в двух местах) — проверяем
    # каждую: расхождение хотя бы в одной означает, что дерево не сошлось.
    _seen=0
    while IFS="$(printf '\t')" read -r k2 key2 tgt; do
        [ "$k2" = "MAP" ] && [ "$key2" = "$key" ] || continue
        _seen=1
        if [ ! -f "$tgt" ]; then
            printf 'нет файла: %s (%s)\n' "$tgt" "$key"; rc=1; continue
        fi
        if [ "$(sha_of "$tgt")" != "$val" ]; then
            printf 'sha не сошлась: %s (%s)\n' "$tgt" "$key"; rc=1
        fi
    done < "$TMP"
    # Путь с суммой, но без адреса — промах install_map: файл объявлен, а
    # доставлять его некуда. Ровно это и ломало 4pda-строку в марте.
    [ "$_seen" = 1 ] || { printf 'нет адреса доставки: %s\n' "$key"; rc=1; }
done < "$TMP"

exit "$rc"
