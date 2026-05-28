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

## Что осталось нативным / нашим

- Детекция/ротация — **нативные** bol-van.
- Примитивы (`multisplit`/`fake`/`hostfakesplit`/`seqovl`/`tcp_ts`/`z2k_http_*`/
  `z2k_game_udp`/`z2k_quic_*`) — **остаются наши** (это не детекция и не ротация).
- `key`/`nld`/`inseq`/`fails`/`time`/`retrans`/`maxseq`/`udp_in`/`udp_out`/`reset`/
  `no_http_redirect` в circular — **нативные** аргументы, остались в config.
- `allow_nohost` — был наш (для Discord STUN без hostname); удалён из config,
  т.к. нативный `standard_hostkey` сам делает fallback на dest-IP для nohost.

## Как вернуть (если native окажется хуже)

1. `git mv archive/custom-detectors-rotation/*.lua files/lua/`
2. Вернуть `--lua-init` блоки в `files/S99zapret2.new`.
3. Вернуть `failure_detector=`/`success_detector=`/`allow_nohost` инъекции в
   `lib/config_official.sh` (см. git history до этого коммита).
4. Вернуть z2k-lua в сборку форка `zapret2-z2k`.
