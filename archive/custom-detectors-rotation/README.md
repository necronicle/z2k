# Archived custom detectors + rotation (2026-05-28)

Эти два lua-модуля **отключены** и перенесены сюда из `files/lua/`. Установка
их больше НЕ грузит (см. `files/S99zapret2.new` — `--lua-init` убраны).

## Почему отключили

Юзеры жаловались на ротацию стратегий (страты «прыгают» / «залипают»).
Кастомная детекция давала false-positives, кастомная ротация-обёртка вела себя
непредсказуемо. Решение — откат на **нативную** detection+rotation bol-van
zapret2 (`standard_failure_detector` / `standard_success_detector` / `circular()`
в `zapret-auto.lua`, встроены в релиз-tarball).

## Что здесь

- **z2k-detectors.lua** — кастомные детекторы:
  `z2k_tls_alert_fatal`, `z2k_tls_stalled`, `z2k_mid_stream_stall`,
  `z2k_success_no_reset`, `z2k_http_success_positive_only` + классификаторы
  (`z2k_classify_http_reply`, `z2k_classify_server_active`, silent-drop).
- **z2k-autocircular.lua** — обёртка над нативным `circular()`:
  sticky-success, nld-pinning, silent-retry, cross-profile bypass.
- **tests/** — юнит-тесты этих модулей, перенесены сюда т.к. тестируют
  заархивированный код (allow_nohost, silent_retry, silent_drop_detector,
  http_classifier, http_mid_stream_stall, mid_stream_stall, probe_override).
  Нативная замена allow_nohost покрыта `tests/test_z2k_nohost_key.lua`.

## Что осталось нативным / нашим

- Детекция/ротация — **нативные** bol-van.
- Примитивы (`multisplit`/`fake`/`hostfakesplit`/`seqovl`/`tcp_ts`/`z2k_http_*`/
  `z2k_game_udp`/`z2k_quic_*`) — **остаются наши** (это не детекция и не ротация).
- `key`/`nld`/`inseq`/`fails`/`time`/`retrans`/`maxseq`/`udp_in`/`udp_out`/`reset`
  в circular — **нативные** аргументы, остались в config.
- `no_http_redirect` — **убран** из всех профилей: его смысл был отдать
  302/307 redirect-классификацию нашему `z2k_classify_http_reply` (теперь в
  архиве). Без классификатора он лишь глушил нативную redirect-детекцию →
  страта на block-page redirect не считалась fail, ротация «залипала».
  Снят → нативная 302/307 detection снова активна.
- `allow_nohost` (был наш wrapper-arg для Discord/STUN UDP без hostname)
  заменён нативным `hostkey=z2k_nohost_key` (`files/lua/z2k-modern-core.lua`,
  через bol-van `arg.hostkey`). Стоковый `standard_hostkey` для nohost-флоу
  делает fallback на dest-IP → Discord voice state фрагментируется по DC-IP
  (cold-start на каждом новом IP). `z2k_nohost_key` возвращает константу
  "nohost" → shared rotation state, как было с allow_nohost. Алгоритм
  ротации при этом остаётся нативным `circular()`.

## Как вернуть (если native окажется хуже)

1. `git mv archive/custom-detectors-rotation/*.lua files/lua/`
2. `git mv archive/custom-detectors-rotation/tests/* tests/`
3. Вернуть `--lua-init` блоки в `files/S99zapret2.new`.
4. Вернуть `failure_detector=`/`success_detector=`/`no_http_redirect`/
   `allow_nohost` инъекции в `lib/config_official.sh` (см. git history до
   этого коммита). При возврате allow_nohost — убрать `hostkey=z2k_nohost_key`
   с discord_udp (взаимозаменяемы).
5. Вернуть z2k-lua в сборку форка `zapret2-z2k`.
