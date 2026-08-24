#!/bin/sh
# lib/release_map.sh — что куда кладётся и что после этого делать.
#
# ЖИВЁТ НА СБОРКЕ, А НЕ НА РОУТЕРЕ, и это главное в этом файле. Обновление
# всегда выполняет СТАРЫЙ апдейтер — тот, что уже стоит на роутере. Пока эти
# таблицы жили в lib/auto_update.sh, правило, добавленное в релизе N, не
# действовало при переходе НА N: новый класс путей старый апдейтер не знал,
# писал «no install target … (skipped)» и двигал версию, не доставив файл.
#
# Теперь таблицы читает только сборка (scripts/gen_file_hashes.sh и
# scripts/release.sh), а результат едет в UPDATES.json данными. Роутер ничего
# не решает — он исполняет.
#
# Файл НЕ деливерабл: z2k_install_paths для него цели не возвращает.

# z2k_install_paths <путь в репозитории> — куда класть на роутере (0..N строк).
# Пусто = файл не доставляется (tests/, scripts/, docs/).
z2k_install_paths() {
    local repo_path="$1"
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    case "$repo_path" in
        lib/release_map.sh)
            # Сам себя не доставляет. Общий lib/* ниже утащил бы этот модуль на
            # роутер, где его никто не читает: адреса и последствия приезжают
            # туда данными в манифесте, а не кодом. Мёртвый файл в /opt/zapret2/lib
            # стоил бы одной лишней загадки при следующем разборе.
            : ;;
        files/lua/*)
            echo "${zd}/lua/${repo_path#files/lua/}"
            ;;
        files/lists/extra-domains.txt)
            # Both shipped baseline and runtime merged copy. Caller treats
            # these as a special case for 3-way merge.
            echo "${zd}/files/lists/extra-domains.txt"
            echo "${zd}/lists/extra-domains.txt"
            ;;
        files/lists/*.txt)
            # IP/host lists that install.sh dual-copies (files/lists/ + lists/).
            echo "${zd}/files/lists/${repo_path#files/lists/}"
            echo "${zd}/lists/${repo_path#files/lists/}"
            ;;
        files/extra_strats/*/Strategy.txt)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/extra_strats/*)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/fake/*)
            echo "${zd}/files/fake/${repo_path#files/fake/}"
            ;;
        files/etc/*)
            echo "${zd}/etc/${repo_path#files/etc/}"
            ;;
        files/init.d/S98z2k-detect)
            # z2k-detect daemon init script — install.sh copies to
            # /opt/etc/init.d (Entware standard), not into $ZAPRET2_DIR.
            echo "/opt/etc/init.d/S98z2k-detect"
            ;;
        files/init.d/S96z2k-rt-proxy)
            # rt-proxy daemon init script — install.sh copies to
            # /opt/etc/init.d (Entware standard), not into $ZAPRET2_DIR.
            echo "/opt/etc/init.d/S96z2k-rt-proxy"
            ;;
        files/init.d/S98tg-tunnel)
            # TG-tunnel supervisor — install.sh copies to /opt/etc/init.d,
            # NOT into $ZAPRET2_DIR. Without this case a patch misplaced it to
            # ${zd}/init.d/ (via files/init.d/* below), missing the live script.
            echo "/opt/etc/init.d/S98tg-tunnel"
            ;;
        files/init.d/S99z2k-scheduler)
            # Same trap, found by the completeness test rather than by another field failure:
            # install.sh:2770 deploys it to /opt/etc/init.d, so a patch touching the scheduler
            # was landing in ${zd}/init.d/ and never reaching the running system.
            echo "/opt/etc/init.d/S99z2k-scheduler"
            ;;
        files/init.d/S51z2k-warp)
            # WARP tunnel supervisor — install.sh copies it to /opt/etc/init.d, NOT into
            # $ZAPRET2_DIR. Without this case a patch touching it lands in ${zd}/init.d/ and is
            # silently lost while installed_tag advances — the r-59.9 failure, again.
            echo "/opt/etc/init.d/S51z2k-warp"
            ;;
        files/init.d/S97z2k-http-tunnel)
            # http-tunnel supervisor — same /opt/etc/init.d placement as above.
            echo "/opt/etc/init.d/S97z2k-http-tunnel"
            ;;
        files/ndm/92-z2k-rt-proxy-redirect.sh)
            echo "/opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh"
            ;;
        files/000-zapret2.sh)
            # Primary NDM netfilter.d recovery hook — install.sh copies it to
            # /opt/etc/ndm/netfilter.d/, NOT into $ZAPRET2_DIR. Without this case
            # it fell into files/*.sh below and a patch misplaced it to
            # ${zd}/000-zapret2.sh, silently skipping the real hook (r-59.9).
            echo "/opt/etc/ndm/netfilter.d/000-zapret2.sh"
            ;;
        files/init.d/*)
            echo "${zd}/init.d/${repo_path#files/init.d/}"
            ;;
        files/S99zapret2.new)
            echo "/opt/etc/init.d/S99zapret2"
            ;;
        files/*.sh|files/*.lua)
            echo "${zd}/${repo_path#files/}"
            ;;
        lib/*)
            # Library scripts (auto_update.sh, install.sh, config*.sh,
            # utils.sh, …) live under $ZAPRET2_DIR/lib at runtime.
            # Without this mapping patch-type releases silently skipped
            # all lib/* changes (no install target).
            echo "${zd}/${repo_path}"
            ;;
        UPDATES.json)
            # The manifest itself ships with the install so that an
            # offline `z2k diag` can show installed_tag context.
            echo "${zd}/${repo_path}"
            ;;
        z2k.sh)
            # Top-level entrypoint. Reinstall flow re-downloads this
            # script separately via au_download_reinstall_script, but
            # patch-type releases touching z2k.sh need the mapping too.
            echo "${zd}/${repo_path}"
            ;;
        webpanel/cgi/*.sh)
            # Webpanel CGI handlers — auth.sh / actions.sh / api.sh.
            # webpanel/install.sh deploys to ${zd}/webpanel/cgi/.
            echo "${zd}/webpanel/cgi/${repo_path#webpanel/cgi/}"
            ;;
        webpanel/www/*)
            # Webpanel static assets — lighttpd serves from ${zd}/www
            # (NOT ${zd}/webpanel/www — webpanel/install.sh copies to
            # the lighttpd document-root which is a separate path).
            echo "${zd}/www/${repo_path#webpanel/www/}"
            ;;
        webpanel/init.d/S96z2k-webpanel)
            echo "/opt/etc/init.d/S96z2k-webpanel"
            ;;
        webpanel/install.sh|webpanel/uninstall.sh)
            echo "${zd}/webpanel/${repo_path#webpanel/}"
            ;;
        webpanel/lighttpd.conf)
            # Generated at install time from a template with @PORT@/@BIND@
            # substitution — see au_reinstall_required() below for the other
            # half of this: patch can't re-template it, so a plain "no target
            # here" is not enough, changing it must force a reinstall release.
            : ;;
        tests/*)
            : # tests are dev/CI artifacts; not shipped to runtime.
            ;;
        *)
            : # no runtime target
            ;;
    esac
}

# z2k_steps_for <путь в репозитории> — что выполнить после доставки (0..N строк).
# Пусто = ничего: файл подхватывается на лету.
#
# Здесь же похоронены четыре прежних правила au_reinstall_required. Они не
# требовали переустановки по существу — им просто нечем было сработать:
#   */builds/*         цель зависит от арки роутера → refresh-binaries
#   config_official.sh генератор, его код не перезапускался → regen-config
#   strategies.sh      то же плюс пересборка extra_strats/*/Strategy.txt
#   lighttpd.conf      конфиг панели шаблонизируется установщиком → rebuild-panel
# lib/install.sh последствий не имеет вовсе: он носитель шагов установки, и
# когда шаги стали вызываться по отдельности, его правка не требует ничего.
#
# webpanel/www/* и webpanel/cgi/* тоже пусты, и это проверено по установщику:
# статика копируется как есть, CGI исполняется на каждый запрос. Перезапускать
# lighttpd ради них не за чем.
z2k_steps_for() {
    case "$1" in
        lib/strategies.sh)
            echo regen-strategies; echo regen-config; echo validate-config; echo restart-service ;;
        lib/config_official.sh)
            echo regen-config; echo validate-config; echo restart-service ;;
        */builds/*)
            echo refresh-binaries ;;
        webpanel/lighttpd.conf)
            echo rebuild-panel ;;
        files/lua/*|files/S99zapret2.new|files/fake/*|files/extra_strats/*)
            echo restart-service ;;
    esac
}

# z2k_all_steps — канонический порядок исполнения. Исполнитель сливает
# объявленные шаги и идёт по этому списку: семь изменившихся lua плюс конфиг
# плюс бинарь дают ОДИН перезапуск в конце, а не девять действий.
z2k_all_steps() {
    echo regen-strategies
    echo regen-config
    echo validate-config
    echo refresh-binaries
    echo rebuild-panel
    echo reset-state
    echo restart-service
}

# z2k_steps_merged <файл …> — объединить последствия набора файлов и выдать их
# в каноническом порядке, каждый максимум один раз.
#
# Единственный аргумент «-» означает «список файлов на stdin, по одному в
# строке». Отдельный признак, а не «нет аргументов»: пустой набор — законный
# случай (релиз, где изменились только списки), и молча уйти читать stdin вместо
# ответа «последствий нет» значило бы повиснуть.
#
# `|| true` на конвейерах ОБЯЗАТЕЛЕН, и это не косметика. Последняя команда
# внутри — `grep -qx`, и когда не совпало ничего (релиз без последствий), она
# возвращает «не найдено». Вызывающий работает под `set -e`, поэтому такой
# конвейер обрывает всю группу — вместе с ещё не выполненным циклом ручных
# шагов. Симптом: релиз с Z2K_RELEASE_STEPS печатает «последствий нет» и
# объявляет пустой список, хотя переменная на месте. Тот же класс, что уже
# ловился в release.sh на голом grep в конце пайпа.
z2k_steps_merged() {
    _zsm_tmp=$(mktemp) || return 1
    if [ "$#" = 1 ] && [ "$1" = "-" ]; then
        while IFS= read -r _zsm_f; do
            [ -n "$_zsm_f" ] && z2k_steps_for "$_zsm_f"
        done | sort -u > "$_zsm_tmp"
    else
        for _zsm_f in "$@"; do z2k_steps_for "$_zsm_f"; done | sort -u > "$_zsm_tmp"
    fi
    z2k_all_steps | while IFS= read -r _zsm_s; do
        grep -qx "$_zsm_s" "$_zsm_tmp" && printf '%s\n' "$_zsm_s"
    done || true
    rm -f "$_zsm_tmp"
    unset _zsm_tmp _zsm_f _zsm_s
    return 0
}

# ---- ПЕРЕХОДНЫЙ ГЕЙТ ---------------------------------------------------------
# z2k_legacy_reinstall_required <путь> — «1», если СТАРЫЙ апдейтер, который
# сейчас стоит на роутерах, доставить эту правку не может ни при каком раскладе.
#
# Живёт ровно до релиза, в котором на роутеры приедет исполнитель шагов: с этого
# момента regen-config, refresh-binaries и rebuild-panel выполняются адресно, и
# гнать полную переустановку ради генератора или бинарника больше незачем.
# Дословный текст прежнего au_reinstall_required — вместе с историей, ради
# которой он появился.
z2k_legacy_reinstall_required() {
    local repo_path="$1"
    case "$repo_path" in
        */builds/*)
            # Arch-specific binaries. au_install_paths() has no target for
            # them at all (the target depends on the router's architecture),
            # so a patch would not deliver them — it would silently drop them
            # from changed_files while the version number moves forward.
            echo 1 ;;
        lib/config_official.sh|lib/strategies.sh)
            # Install-time generators: their code runs exactly once, during
            # step_create_config_and_init, and the result (config,
            # extra_strats/*/Strategy.txt) is written to disk as plain files.
            # A patch overwrites the .sh source but does not re-run it — an
            # already-installed router keeps the old generated output.
            echo 1 ;;
        lib/install.sh)
            # Тот же класс, что и генераторы выше, и он тут отсутствовал: весь
            # код install.sh выполняется ТОЛЬКО внутри установки (step_*,
            # migrate_*). Патч кладёт свежий файл в ${zd}/lib/install.sh и на
            # этом всё — ни один его шаг не переигрывается, а reinstall и вовсе
            # качает модули заново, так что доставленная копия не участвует даже
            # в следующей установке. Релиз, где изменился только install.sh,
            # уезжал бы патчем: версия вперёд, installed_tag вперёд, поведение
            # роутера ровно прежнее — авария без единой строчки в логе.
            #
            # ПОЧЕМУ НЕ ВЕСЬ lib/*. Остальные модули (utils, menu, config,
            # webpanel, auto_update) z2k.sh пересобирает в память на КАЖДОМ
            # запуске из ${zd}/lib — их правку патч доставляет по-настоящему.
            # Загонять и их в reinstall значило бы платить полной переустановкой
            # за однострочный фикс в меню.
            echo 1 ;;
        webpanel/lighttpd.conf)
            # Templated with @PORT@/@BIND@ substitution at install time
            # (webpanel/install.sh). A patch has no re-templating step, so it
            # would overwrite nothing and the router keeps the stale config.
            echo 1 ;;
    esac
}

# z2k_steps_merged_names — то же упорядочивание, но на входе уже ИМЕНА шагов,
# а не пути файлов. Нужно, чтобы объявленные вручную шаги (Z2K_RELEASE_STEPS)
# слились с выведенными из диффа в один канонический порядок, а не приписались
# хвостом. Неизвестное имя пропускаем в конец: пусть упрётся исполнитель и
# потребует полную переустановку, а не тихо потеряется на сборке.
z2k_steps_merged_names() {
    _zsn_tmp=$(mktemp) || return 1
    sort -u > "$_zsn_tmp"
    z2k_all_steps | while IFS= read -r _zsn_s; do
        grep -qx "$_zsn_s" "$_zsn_tmp" && printf '%s\n' "$_zsn_s"
    done || true
    while IFS= read -r _zsn_s; do
        [ -n "$_zsn_s" ] || continue
        z2k_all_steps | grep -qx "$_zsn_s" || printf '%s\n' "$_zsn_s"
    done < "$_zsn_tmp" || true
    rm -f "$_zsn_tmp"
    unset _zsn_tmp _zsn_s
    return 0
}
