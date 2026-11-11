# Проверка соответствия актуальному запросу

FR-001 — выполнено. Точность отката проверена 2026-11-11, без запуска тестов.
Архив p-87.31 заново извлечён `git archive p-87.31` в `/private/tmp/claude-501/-Library-Zapret2/ff2b0266-5463-4948-8e5b-1931c8363afb/scratchpad/ytrevert/p8731-final`.
Генератор: `/private/tmp/claude-501/-Library-Zapret2/ff2b0266-5463-4948-8e5b-1931c8363afb/scratchpad/ytrevert/../ytdiff/generate-production.sh` — реальные пулы strats_new2.txt/quic_strats.ini, одинаковые пути нормализованы в /opt/zapret2.
Для каждого дерева и режима выполнялось:
```sh
sh "$B/../ytdiff/generate-production.sh" "$SRC" "$OUT" "$MODE"
```
SRC: `$B/p8731-final` и текущее `/Library/Zapret2/z2k`; MODE: defaults, missing; OUT: final-31-$MODE / final-current-$MODE.
Проверка полного вывода (включает все видео/GV/YT/QUIC/RKN профили):
```sh
B=/private/tmp/claude-501/-Library-Zapret2/ff2b0266-5463-4948-8e5b-1931c8363afb/scratchpad/ytrevert
for m in defaults missing; do
  diff -u "$B/final-31-$m/args.txt" "$B/final-current-$m/args.txt"
done
git diff p-87.31 -- z2k-detect/internal/gvsub
```
Результат: оба diff генератора exit 0, output 0 байт; gvsub diff 0 байт, включая тестовые файлы.
`git diff p-87.31 -- files/S99zapret2.new files/lists files/lua files/z2k-geosite.sh z2k-detect/internal/gvsub` — пустой.
Видео-тексты панели уже совпадали с p-87.31: отличие только cache-buster версии, оставлен HEAD p-87.36.

FR-002 — выполнено. TG builds восстановлены командой `git checkout HEAD -- mtproxy-client/builds`. Diff mtproxy-client, .github, rt-proxy, webpanel против исходного HEAD пустой. AGH/диагностика/Instagram из HEAD не менялись. В генераторе относительно p-87.31 сохранён только механизм toggle-values-v1. Явные значения всех зарегистрированных тумблеров роутера до/после одинаковы (changed_explicit_toggles=0). Видео defaults и сами ключи p-87.31 совпадают с сохранённым registry.

FR-003 — выполнено. `make -C z2k-detect linux-arm64`, Go 1.25.13, успешно. Остальные уже собранные детекторы из прерванной задачи сохранены; TG заново не собирался.
Backup до замены: `/opt/zapret2/backup-pre-p8737-test/p8736/`; исходный initial не менялся. BusyBox tar не умеет создавать архивы: использованы cp -a и paths.txt/absent.txt/complete. Сохранены все цели замены, config, state, autocircular/state.tsv и fallback.
Доставка: карта release_map.sh, используемая auto_update.sh, плюс рабочая материализованная extra_strats/TCP/YT_GV/List.txt. MD5 всех 8 целей совпадает с локальными файлами (`final-delivery-md5.txt`). В рабочем extra_strats/TCP/YT/List.txt восстановлен удалённый p-87.36 geosite домен gvt1.com; список до изменения дополнительно сохранён в тот же backup. Остальные рабочие домены не затирались.
Вызов regen через updater в отдельном shell завершился с кодом 1 до рестарта; явный source utils/config_official/strategies и create_official_config успешно регенерировал config, после чего S99 перезапущен.
Финальное время restart: **2026-11-11 21:24:59 MSK**.
MD5 z2k-detect: `41b170a71132cd5ab611e39219382776` (до: `2b4f1b1b5147d40fba438e5bac23c5dd`).
MD5 TG: `641f40dd64bc276dc74c90bea979478b` — до/после одинаковый, HEAD p-87.36.
В 21:25:14 MSK: nfqws2 PID 3846, gvsub PID 3979/queue 210; diag «явных проблем не найдено»; свежий Telegram CONNECT_OK в 18:25:02 UTC. В diag отображается прежняя метка p-87.33: метаданные версии этим ручным откатом не обновлялись, состояние кода подтверждено md5.
Логи: `/private/tmp/claude-501/-Library-Zapret2/ff2b0266-5463-4948-8e5b-1931c8363afb/scratchpad/ytrevert/final-restart-gvt1.log`, `final-health-complete.txt`, `final-regen.log`.
Уже удалённые gv-named-state-v2 записи не восстанавливались; p-87.31 принимает оставшиеся записи, маркер v2 без потребителя безвреден. State не сбрасывался.

Откат роутера на сохранённые файлы p-87.36:
```sh
ssh -p 222 root@192.168.1.1 'sh /opt/zapret2/backup-pre-p8737-test/p8736/rollback.sh'
```
Скрипт останавливает S99, возвращает сохранённые файлы/config/state и списки, перезапускает службу, печатает md5. Сам откат не запускался.

FR-004 — реализация и доказательства подготовлены для локального коммита с требуемой атрибуцией. Теги, release.sh, RELEASE_APPROVED и push не выполнялись.
Тесты, CI, race, YouTube/Play замеры в этом продолжении не запускались по актуальному запрету владельца. Качество воспроизведения не измерено и не заявляется; незакрытых требований актуальной задачи нет после локальной фиксации.
