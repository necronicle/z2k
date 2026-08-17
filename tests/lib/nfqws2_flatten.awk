# tests/lib/nfqws2_flatten.awk — раскрывает --template/--import в NFQWS2_OPT.
#
# ЗАЧЕМ. Генератор объявляет общий арсенал один раз (--template=имя) и
# подставляет его в профили (--import=имя) — так профиль cf_extra перестал быть
# дословной 13-килобайтной копией rkn_tcp. Но проверки (и наши тесты, и глаз
# человека) рассуждают о профиле как о ЦЕЛОЙ строке: «в rkn_tcp есть padencap»,
# «в этом профиле столько-то стратегий». Этот фильтр возвращает такой взгляд:
# на выходе по строке на профиль, где вместо --import стоит тело шаблона.
#
# Вход: тело NFQWS2_OPT (может быть многострочным).
# Выход: по строке на КАЖДЫЙ рабочий профиль; блоки-шаблоны не печатаются.
#
# Порядок токенов сохраняется как есть: он значим (--payload/--in-range
# действуют на все последующие инстансы), поэтому здесь ничего не сортируется
# и не дедуплицируется. Это раскрыватель, а не нормализатор.

{ all = all " " $0 }

function expand(body, depth,    i, n, parts, out, nm) {
    if (depth > 8) {
        print "FLATTEN-ERROR: слишком глубокая вложенность --import" > "/dev/stderr"
        exit 2
    }
    n = split(body, parts, " ")
    out = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] == "") continue
        if (parts[i] ~ /^--import=/) {
            nm = substr(parts[i], 10)
            if (!(nm in TPL)) {
                print "FLATTEN-ERROR: импорт неизвестного шаблона " nm > "/dev/stderr"
                exit 2
            }
            out = out " " expand(TPL[nm], depth + 1)
        } else {
            out = out " " parts[i]
        }
    }
    sub(/^ /, "", out)
    return out
}

# Имя блока: --template=NAME или --template рядом с --name=NAME.
function block_name(body,    i, n, parts, nm) {
    n = split(body, parts, " ")
    nm = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^--template=/) nm = substr(parts[i], 12)
        else if (parts[i] ~ /^--name=/ && nm == "") nm = substr(parts[i], 8)
    }
    return nm
}

function is_template(body,    i, n, parts) {
    n = split(body, parts, " ")
    for (i = 1; i <= n; i++)
        if (parts[i] == "--template" || parts[i] ~ /^--template=/) return 1
    return 0
}

# Тело блока без служебных токенов объявления шаблона.
function strip_decl(body,    i, n, parts, out) {
    n = split(body, parts, " ")
    out = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] == "") continue
        if (parts[i] == "--template" || parts[i] ~ /^--template=/) continue
        out = out " " parts[i]
    }
    sub(/^ /, "", out)
    return out
}

END {
    nb = split(all, blocks, / --new( |$)/)
    # Первый проход — собрать шаблоны (объявление всегда РАНЬШЕ импорта).
    for (b = 1; b <= nb; b++) {
        if (blocks[b] ~ /^[ \t]*$/) continue
        if (is_template(blocks[b])) {
            nm = block_name(blocks[b])
            if (nm == "") continue          # безымянный шаблон недостижим
            TPL[nm] = strip_decl(blocks[b])
        }
    }
    # Второй — напечатать рабочие профили с раскрытыми импортами.
    for (b = 1; b <= nb; b++) {
        if (blocks[b] ~ /^[ \t]*$/) continue
        if (is_template(blocks[b])) continue
        line = expand(blocks[b], 0)
        if (line != "") print line
    }
}
