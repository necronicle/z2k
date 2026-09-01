#!/bin/sh
# tests/test_stock_lighttpd_disarmed.sh — стоковый lighttpd не должен отнимать
# 80-й порт у вебморды роутера.
#
# ЧТО БЫЛО. Пакет lighttpd мы ставим ради своей панели, а он приносит свой
# автостартующий init со стоковым конфигом: ни server.port, ни server.bind, то
# есть 0.0.0.0:80. На Keenetic 80-й принадлежит роутеру, и при загрузке идёт
# гонка — S80lighttpd стартует раньше нашего S96.
#
# Поле 01.09.2026: `0.0.0.0:80 LISTEN 1353/lighttpd` при порте панели 8088, и в
# журнале роутера bind() failed на всех адресах подряд, включая петлевой,
# следом «Service: Nginx: unexpectedly stopped». Интернет работал: маршрутизация
# в ядре, а морду отдаёт упавшая служба.
#
# Проверяется ИСПОЛНЕНИЕМ настоящей _z2k_disarm_stock_lighttpd из
# files/S99zapret2.new.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

eval "$(awk '/^_z2k_disarm_stock_lighttpd\(\)/,/^}/' "$ROOT/files/S99zapret2.new")"
command -v _z2k_disarm_stock_lighttpd >/dev/null 2>&1 \
    || { bad "функция не извлеклась из S99zapret2.new"; printf '\nPASSED: 0\nFAILED: 1\n'; exit 1; }

# Песочница вместо настоящих путей: функция ходит в /opt/etc, поэтому подменяем
# её же командами через PATH нельзя — переопределяем пути через обёртку.
mk() {  # mk <порт в конфиге|пусто> — собрать /opt-песочницу
    rm -rf "$SB/opt"; mkdir -p "$SB/opt/etc/init.d" "$SB/opt/etc/lighttpd/conf.d"
    printf '#!/bin/sh\nexit 0\n' > "$SB/opt/etc/init.d/S80lighttpd"
    chmod +x "$SB/opt/etc/init.d/S80lighttpd"
    printf '#!/bin/sh\nexit 0\n' > "$SB/opt/etc/init.d/S96z2k-webpanel"
    chmod +x "$SB/opt/etc/init.d/S96z2k-webpanel"
    if [ -n "$1" ]; then
        printf 'server.port = %s\n' "$1" > "$SB/opt/etc/lighttpd/lighttpd.conf"
    else
        printf 'server.document-root = "/opt/share/www/"\n' > "$SB/opt/etc/lighttpd/lighttpd.conf"
    fi
}

# Запуск функции с подменённым корнем: копируем её тело, заменив /opt на песочницу.
run() {
    awk '/^_z2k_disarm_stock_lighttpd\(\)/,/^}/' "$ROOT/files/S99zapret2.new" \
        | sed "s#/opt/etc#$SB/opt/etc#g" > "$SB/fn.sh"
    ( . "$SB/fn.sh"; _z2k_disarm_stock_lighttpd ) 2>&1
}

# --- 1. Конфиг без порта = умолчание 80 = глушим ------------------------------
mk ""
out=$(run)
if [ ! -e "$SB/opt/etc/init.d/S80lighttpd" ] \
   && [ -e "$SB/opt/etc/init.d/.S80lighttpd.disabled-by-z2k" ]; then
    ok "конфиг без server.port (умолчание 80) — init обезврежен"
else
    bad "init не обезврежен при умолчании 80: [$out]"
fi
case "$out" in
    *80*) ok "в вывод попало объяснение про 80-й порт" ;;
    *)    bad "молча переименовали, человек не поймёт почему: [$out]" ;;
esac

# --- 2. Имя совпадает с тем, что возвращает удаление --------------------------
# lib/install.sh при удалении ищет ровно .S*lighttpd.disabled-by-z2k — разъедется
# имя, и человек останется без штатного lighttpd навсегда и без следа почему.
if grep -q '\.S\*lighttpd\.disabled-by-z2k' "$ROOT/lib/install.sh"; then
    ok "имя отключённого файла совпадает с шаблоном возврата при удалении"
else
    bad "удаление больше не находит наш файл — возврат сломан"
fi

# --- 3. Чужой lighttpd на другом порту не трогаем ------------------------------
mk 81
out=$(run)
if [ -e "$SB/opt/etc/init.d/S80lighttpd" ]; then
    ok "lighttpd на 81 оставлен в покое — он нам не мешает"
else
    bad "снесли чужой init, который никому не мешал"
fi

# --- 4. Наш собственный init не трогаем никогда --------------------------------
mk ""
run >/dev/null
if [ -e "$SB/opt/etc/init.d/S96z2k-webpanel" ]; then
    ok "собственный init панели не тронут"
else
    bad "функция отключила нашу же панель"
fi

# --- 5. Повторный запуск не ломается и не плодит мусор -------------------------
# Функция зовётся при КАЖДОМ старте сервиса, а не однажды.
mk ""
run >/dev/null
before=$(ls -a "$SB/opt/etc/init.d" | wc -l | tr -d ' ')
out=$(run)
after=$(ls -a "$SB/opt/etc/init.d" | wc -l | tr -d ' ')
if [ "$before" = "$after" ]; then
    ok "повторный запуск ничего не меняет"
else
    bad "повторный запуск наплодил файлов: было $before, стало $after"
fi

# --- 6. Пакет переустановили — init вернулся — глушим снова --------------------
mk ""
run >/dev/null
printf '#!/bin/sh\nexit 0\n' > "$SB/opt/etc/init.d/S80lighttpd"
chmod +x "$SB/opt/etc/init.d/S80lighttpd"
run >/dev/null
if [ ! -e "$SB/opt/etc/init.d/S80lighttpd" ]; then
    ok "вернувшийся после переустановки пакета init обезврежен снова"
else
    bad "после переустановки пакета мина встала обратно и осталась"
fi

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
