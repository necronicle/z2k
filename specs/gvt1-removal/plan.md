# Implementation Plan: gvt1 removal
Основа: spec.md; официальные локальные шаблоны Spec Kit spec/plan/tasks прочитаны. Существующий проект не переинициализируется.

## Technical Context
POSIX sh/awk, Lua, Entware. Данные: hostlists, TSV primary/fallback и .pre-*.
Расширить существующий filter_google_domains и normalize_autohost_domains.
S99: атомарная миграция под lock с done только после успеха, до всех восстановлений состояния и direct start_daemons.
Lua: отвергать gvt1 hostkeys в общей нормализации, включая merge/persist.
Не создавать whitelist или новые исключения движка.

## Verification
Тесты поставляемых списков, реального apply_new_list, offline cleanup, autohost сборки, миграции (снимки, все пулы, lock/failure/no-op), Lua load/save.
Затронутые shell/Lua наборы и линтеры. Затем backup, доставка по release_map, restart и проверка живости.

## Constraints
Сохранить чужие изменения. Не трогать initial/p8736. Не выпускать и не выполнять замеры.
