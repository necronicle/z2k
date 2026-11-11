# Verification: gvt1 removal

## FR-001: списки и сборка
В files/lists/extra_strats/TCP/YT/List.txt удалена строка 7, в UDP/YT/List.txt — строка 6 (по 1 строке gvt1.com).
Полный поиск gvt1 по рабочему репозиторию, включая скрытые/игнорируемые файлы, выполнен: положительные поставляемые записи были только в этих двух списках. Генераторы больше не содержат положительного включения. Исторические отчёты/локальные диагностические данные и тест нормализации имён не являются поставляемыми списками и сохранены.
filter_google_domains в files/z2k-geosite.sh удаляет apex/поддомены с учётом регистра и trailing dot при публикации и offline cleanup. Очистка охватывает live, .shipped, обе updater-копии, raw/накопленный autohostlist. normalize_autohost_domains в S99 предотвращает повторное включение при сборке.
z2k-update-lists.sh уже вызывает geosite fetch; исполняемый test_geosite_inject проверяет cleanup при 304 и сетевом отказе. Дополнительная копия фильтра в updater не требуется.
Whitelist/исключения движка не пополнялись; пользовательские extra-domains не изменялись (это проверяет test_gvt1_lists.sh). README приведён к реальному охвату видео.

## FR-002: состояние
S99 _z2k_migrate_gvt1_state_v1 вызывается до прежних миграций/восстановления и в direct start_daemons до запуска nfqws2. Маркер state/gvt1-state-v1.done ставится только после успешной очистки всех файлов. Используются штатный каталог state (сохраняется установщиком), блокировка, temp+rename, повтор после частичного отказа.
Очищаются любые пулы и режимы primary state.tsv, fallback /tmp/z2k-autocircular-state.tsv и их .pre-*; новые загрязнённые снимки не создаются. Lua общая нормализация отвергает эти hostkeys при load/merge/get_record/persist, чтобы старые строки не воскресли при сохранении.
Исполняемый test_gvt1_state_migration проверяет все пулы, IPv4/IPv6, wildcard/subdomain, frozen, соседние имена, primary/fallback snapshots, lock/partial retry, fail-closed startup и no-op после done. test_gvt1_persist проверяет настоящий Lua load/merge/save.

## FR-003: RED → GREEN
На базе 37509494 до изменения production-кода:
- test_gvt1_lists.sh shipped/build/offline/auto: все четыре режима exit 1; gvt1 переживает публикацию/очистку/нормализацию.
- test_gvt1_state_migration.sh: exit 1, [FAIL] no gvt1 migration.
- test_gvt1_persist.sh: exit 1, gvt1 loaded from disk.
После исправления 20 наборов под dash завершились успешно:
- test_autohostlist_wiring.sh
- test_custom_voice_blob_migration.sh
- test_geosite_apply_guard.sh
- test_geosite_cache_survives_reinstall.sh
- test_geosite_inject.sh
- test_geosite_rkn_asset.sh
- test_gv_named_state_migration.sh
- test_gvt1_lists.sh
- test_gvt1_persist.sh
- test_gvt1_state_migration.sh
- test_install_lists_match_map.sh
- test_rkn_fp_reaches_hostlist.sh
- test_state_pool_renumber_migration.sh
- test_state_pool_renumber_v2.sh
- test_state_pool_renumber_v3.sh
- test_state_pool_renumber_v5.sh
- test_state_rerun_after_reinstall.sh
- test_state_sld_migration.sh
- test_z2k_state_persist.sh

ShellCheck затронутых shell-файлов: --severity=warning и --exclude=SC1007,SC1090,SC1091,SC3043,SC3040,SC2034,SC2148,SC2154 (как scripts/ci_local.sh), exit 0.
luacheck files/lua/*.lua --codes -q: 0 warnings / 0 errors в 9 файлах.
dash -n обоих production shell-файлов и git diff --check: exit 0.
Полный ci_local не запускался, согласно указанию владельца.

## FR-005: роутер
Бэкап 22 существовавших затрагиваемых файлов создан в /opt/zapret2/backup-pre-p8737-test/gvt1/rootfs до доставки; existing.txt/absent.txt описывают восстановление. initial и p8736 не изменялись.
Семь целей по lib/release_map.sh доставлены; MD5 7/7 совпадает (delivery-map.tsv).
Штатный /opt/etc/init.d/S99zapret2 restart завершился успешно. Миграция выполнена до подъёма нового nfqws2. Точные счётчики, пустой grep всех управляемых списков/state/.pre-*, сохранность остальных строк снимков, PID и свежий Telegram CONNECT_OK — router-health.txt.
Готовность: 2026-11-11 21:41:05 МСК. nfqws2 17028, gvsub 17068.
Откат: ssh -p 222 root@192.168.1.1 'sh /opt/zapret2/backup-pre-p8737-test/gvt1/restore.sh'
Замеры не выполнялись. Проверка обновления Play остаётся владельцу; это не проверенное агентом утверждение о пользовательском результате.

## FR-004: локальный коммит
Сообщение: «gvt1.com: убрать из списков и стратегий»; Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>.
Теги, release.sh, RELEASE_APPROVED и push не выполнялись. Сторонние незакоммиченные файлы сохранены.
