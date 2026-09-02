#!/bin/sh
# tests/test_release_map.sh — таблицы соответствий: куда класть и что делать после.
#
# Живут на СБОРКЕ, а не на роутере: правило, добавленное в релизе N, должно
# действовать при переходе НА N, а роутер исполняет старый код и всегда
# опаздывает на релиз (см. спек, «опоздание на релиз»).
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZAPRET2_DIR=/opt/zapret2; export ZAPRET2_DIR
# shellcheck disable=SC1091
. "$ROOT/lib/release_map.sh"

p() { z2k_install_paths "$1" | tr '\n' '|'; }
s() { z2k_steps_for "$1" | sort | tr '\n' ' '; }

assert_eq "lua → каталог lua"        "/opt/zapret2/lua/x.lua|" "$(p files/lua/x.lua)"
assert_eq "список → две цели"        "/opt/zapret2/files/lists/a.txt|/opt/zapret2/lists/a.txt|" "$(p files/lists/a.txt)"
assert_eq "модуль lib"               "/opt/zapret2/lib/menu.sh|" "$(p lib/menu.sh)"
assert_eq "init.d вне ZAPRET2_DIR"   "/opt/etc/init.d/S51z2k-warp|" "$(p files/init.d/S51z2k-warp)"
assert_eq "статика панели"           "/opt/zapret2/www/js/app.js|" "$(p webpanel/www/js/app.js)"
assert_eq "не деливерабл"            "" "$(p tests/test_x.sh)"
assert_eq "бинарник — не по общему пути" "" "$(p z2k-warpd/builds/z2k-warpd-linux-arm64)"

# Доставляемость — адрес ИЛИ шаг. Релиз из одних бинарников доставляем
# (refresh-binaries), а vps-relay/, docs и тесты — нечем и незачем.
d() { if z2k_is_deliverable "$1"; then echo yes; else echo no; fi; }
assert_eq "бинарник доставляем (шагом)"    "yes" "$(d mtproxy-client/builds/tg-mtproxy-client-linux-arm64)"
assert_eq "скрипт доставляем (адресом)"    "yes" "$(d files/z2k-scheduler.sh)"
assert_eq "код релея не доставляем"        "no"  "$(d vps-relay/main.go)"
assert_eq "тест не доставляем"             "no"  "$(d tests/test_x.sh)"
assert_eq "исходник клиента не доставляем" "no"  "$(d mtproxy-client/tunnel.go)"

assert_eq "генератор конфига"        "regen-config restart-service validate-config " "$(s lib/config_official.sh)"
assert_eq "генератор стратегий"      "regen-config regen-strategies restart-service validate-config " "$(s lib/strategies.sh)"
assert_eq "lua → только рестарт"     "restart-service " "$(s files/lua/x.lua)"
assert_eq "бинарник"                 "refresh-binaries " "$(s z2k-warpd/builds/z2k-warpd-linux-arm64)"
assert_eq "панель"                   "rebuild-panel " "$(s webpanel/lighttpd.conf)"
assert_eq "список — без последствий" "" "$(s files/lists/a.txt)"
assert_eq "install.sh — без последствий (носитель шагов установки)" "" "$(s lib/install.sh)"

assert_eq "канонический порядок" \
  "regen-strategies regen-config validate-config refresh-binaries rebuild-panel reset-state restart-service cleanup-ip-hosts" \
  "$(z2k_all_steps | tr '\n' ' ' | sed 's/ $//')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
