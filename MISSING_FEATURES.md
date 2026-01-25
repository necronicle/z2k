# Пропущенные функции из install_easy.sh

Сравнение нашей установки с официальным install_openwrt():

## ✅ ЧТО РЕАЛИЗОВАНО:

1. **check_bins** - проверка наличия бинарников
   - У нас: вызывается через install_bin.sh ✅

2. **install_binaries** - установка бинарников
   - У нас: step_build_zapret2() вызывает install_bin.sh ✅

3. **install_sysv_init** - установка init скрипта
   - У нас: step_create_config_and_init() ✅

4. **download_list** - загрузка списков доменов
   - У нас: своя система через z4r (download_domain_lists) ✅

5. **Модули common/**
   - У нас: новый init скрипт использует их ✅

---

## ❌ ЧТО ПРОПУЩЕНО (КРИТИЧНО):

### 1. **require_root** - проверка root прав
```bash
# Официальный:
require_root()

# У нас: НЕТ
# Проблема: установка может частично пройти без root
```

**Где добавить:** В начале run_full_install()

---

### 2. **check_dns** - проверка работы DNS
```bash
# Официальный:
check_dns() {
    nslookup w3.org >/dev/null 2>/dev/null
}

# У нас: НЕТ
# Проблема: не узнаем если DNS не работает (РКН блокировка)
```

**Где добавить:** Перед step_build_zapret2()

---

### 3. **select_fwtype** - определение типа firewall (КРИТИЧНО!)
```bash
# Официальный:
select_fwtype() {
    linux_fwtype  # автоопределение iptables/nftables
    # asks user to choose if both available
}

# У нас: НЕТ
# Проблема: может выбрать неправильный тип firewall
# Keenetic обычно использует iptables, но надо проверять!
```

**Где добавить:** В step_create_config_and_init() перед созданием config

**ВАЖНО:** В config файле должна быть переменная FWTYPE!

---

### 4. **select_ipv6** - настройка IPv6
```bash
# Официальный:
select_ipv6() {
    ask_yes_no "$DISABLE_IPV6" "disable ipv6"
    DISABLE_IPV6=$?
    write_config_var DISABLE_IPV6
}

# У нас: hardcoded DISABLE_IPV6=0 в config
# Проблема: не даём выбора, IPv6 всегда включен
```

**Где добавить:** Опционально в config (у нас есть дефолт)

---

### 5. **check_prerequisites_openwrt** - установка зависимостей (КРИТИЧНО!)
```bash
# Официальный:
check_prerequisites_openwrt() {
    # Проверяет и устанавливает:
    # - curl
    # - iptables/nftables
    # - ipset
    # - iptables-mod-nfqueue, iptables-mod-extra
    # - GNU gzip/sort (оптимизация)
}

# У нас: step_install_dependencies() устанавливает только:
# - libmnl, libnetfilter-queue, libnfnetlink, libcap, zlib, curl, unzip
# НЕ УСТАНАВЛИВАЕМ:
# - ipset (критично!)
# - iptables-mod-nfqueue (критично!)
# - iptables-mod-extra
# - GNU gzip, GNU sort
```

**Где добавить:** В step_install_dependencies() или отдельный шаг

---

### 6. **ask_config_offload / deoffload_openwrt_firewall** - flow offloading
```bash
# Официальный:
ask_config_offload() {
    # Выбор: donttouch/none/software/hardware
    FLOWOFFLOAD=...
}
deoffload_openwrt_firewall() {
    # Отключает system-wide flow offloading если nfqws используется
    uci set firewall.@defaults[0].flow_offloading=0
}

# У нас: НЕТ
# Проблема: flow offloading может ломать DPI bypass!
# На Keenetic может быть включен hardware NAT offloading
```

**Где добавить:**
- step_disable_hwnat() - расширить для проверки flow offloading
- В config: FLOWOFFLOAD=none

---

### 7. **crontab_add** - автообновление списков доменов
```bash
# Официальный:
crontab_add 0 6  # обновление в 6:00 ночи
cron_ensure_running

# У нас: НЕТ
# Проблема: списки доменов не обновляются автоматически
```

**Где добавить:** В step_finalize() или отдельный шаг

**Для z2k:** можно не делать, так как у нас списки от z4r, не от antifilter

---

### 8. **install_openwrt_iface_hook** - хук для перезагрузки при смене интерфейсов
```bash
# Официальный:
install_openwrt_iface_hook() {
    # Копирует 90-zapret2 в /etc/hotplug.d/iface/
    # Перезапускает firewall при смене WAN интерфейса
}

# У нас: НЕТ (но есть NDM netfilter hook)
# На Keenetic: используем /opt/etc/ndm/netfilter.d/000-zapret2.sh
```

**Где:** У нас уже есть аналог - install_netfilter_hook() ✅

---

### 9. **check_virt** - проверка виртуализации
```bash
# Официальный:
check_virt() {
    # Определяет: docker, lxc, openvz и предупреждает
    # Некоторые техники могут не работать в контейнерах
}

# У нас: НЕТ
# Проблема: не критично для Keenetic (железный роутер)
```

**Где:** Можно не делать для Keenetic

---

### 10. **check_location / copy_openwrt** - проверка что запущено из правильного места
```bash
# Официальный:
check_location copy_openwrt
# Проверяет что скрипт запущен из /opt/zapret2
# Если нет - копирует туда и relaunches

# У нас: НЕТ
# Проблема: z2k всегда работает из /tmp/z2k и ставит в /opt/zapret2
```

**Где:** Не нужно для z2k (другая архитектура)

---

## 📊 ПРИОРИТЕТЫ РЕАЛИЗАЦИИ:

### 🔴 КРИТИЧНО (Must Have):
1. **check_prerequisites_openwrt** - установка ipset, iptables-mod-nfqueue
2. **select_fwtype** - определение iptables/nftables
3. **require_root** - проверка root прав
4. **deoffload_openwrt_firewall** - отключение flow offloading

### 🟡 ВАЖНО (Should Have):
5. **check_dns** - проверка DNS (РКН блокировка)
6. **ask_config_offload** - настройка flow offloading в config
7. **select_ipv6** - выбор IPv6 (сейчас hardcoded)

### 🟢 ЖЕЛАТЕЛЬНО (Nice to Have):
8. **crontab_add** - автообновление (но у нас z4r, не antifilter)
9. **check_virt** - предупреждение о виртуализации
10. **GNU gzip/sort** - оптимизация (предложение в check_prerequisites)

---

## 🔧 ПЛАН ИСПРАВЛЕНИЯ:

### Шаг 1: Добавить критичные функции в lib/install.sh

```bash
# Новая функция перед step_update_packages
step_check_root() {
    print_header "Проверка прав"

    if [ "$(id -u)" -ne 0 ]; then
        print_error "Требуются root права"
        print_info "Запустите: sudo sh z2k.sh install"
        return 1
    fi

    print_success "Root права подтверждены"
    return 0
}

# Новая функция перед step_build_zapret2
step_check_dns() {
    print_header "Проверка DNS"

    if nslookup github.com >/dev/null 2>&1; then
        print_success "DNS работает"
        return 0
    else
        print_warning "DNS не работает или заблокирован"
        print_info "Возможна блокировка РКН"

        printf "Продолжить установку? [Y/n]: "
        read -r answer </dev/tty
        case "$answer" in
            [Nn]*) return 1 ;;
            *) return 0 ;;
        esac
    fi
}

# Новая функция
step_check_and_select_fwtype() {
    print_header "Определение типа firewall"

    # Source модуль fwtype
    . "${ZAPRET2_DIR}/common/fwtype.sh"

    # Автоопределение
    linux_fwtype

    print_info "Обнаружен firewall: $FWTYPE"

    # Записать в config
    local config="${ZAPRET2_DIR}/config"
    if [ -f "$config" ]; then
        # Update FWTYPE in config
        sed -i "s/^#*FWTYPE=.*/FWTYPE=$FWTYPE/" "$config"
        print_success "FWTYPE=$FWTYPE записан в config"
    fi

    return 0
}

# Расширить step_install_dependencies
step_install_dependencies() {
    # ... существующий код ...

    # ДОБАВИТЬ:
    print_info "Установка критичных зависимостей для zapret2..."

    # ipset - КРИТИЧНО для фильтрации
    if ! opkg list-installed | grep -q "^ipset "; then
        print_info "Установка ipset..."
        opkg install ipset || print_warning "Не удалось установить ipset"
    fi

    # iptables-mod-nfqueue - КРИТИЧНО для NFQUEUE
    if ! opkg list-installed | grep -q "iptables-mod-nfqueue"; then
        print_info "Установка iptables-mod-nfqueue..."
        opkg install iptables-mod-nfqueue || print_warning "Не удалось установить iptables-mod-nfqueue"
    fi

    # iptables-mod-extra - для дополнительных match модулей
    if ! opkg list-installed | grep -q "iptables-mod-extra"; then
        print_info "Установка iptables-mod-extra..."
        opkg install iptables-mod-extra || print_warning "Не удалось установить iptables-mod-extra"
    fi

    # Предложить GNU gzip/sort для производительности
    if [ -L "/opt/bin/gzip" ] && readlink /opt/bin/gzip | grep -q busybox; then
        print_info "Обнаружен busybox gzip (медленный)"
        printf "Установить GNU gzip для ускорения? [y/N]: "
        read -r answer </dev/tty
        case "$answer" in
            [Yy]*) opkg install --force-overwrite gzip ;;
        esac
    fi
}
```

### Шаг 2: Обновить run_full_install() порядок

```bash
run_full_install() {
    # Добавить новые шаги:
    step_check_root || return 1                    # ← НОВОЕ
    step_update_packages || return 1
    step_install_dependencies || return 1          # ← обновить
    step_load_kernel_modules || return 1
    step_check_dns || return 1                     # ← НОВОЕ
    step_build_zapret2 || return 1
    step_verify_installation || return 1
    step_download_domain_lists || return 1
    step_check_and_select_fwtype || return 1       # ← НОВОЕ
    step_disable_hwnat || return 1                 # ← расширить для flow offloading
    step_create_config_and_init || return 1
    step_install_netfilter_hook || return 1
    step_finalize || return 1
}
```

### Шаг 3: Обновить config_official.sh

Добавить в create_official_config():
- Автоопределение FWTYPE
- FLOWOFFLOAD=none по умолчанию
- Опции для ipset

---

## ✅ ЧТО УЖЕ РАБОТАЕТ ПРАВИЛЬНО:

1. **Модули common/** - новый init скрипт их использует ✅
2. **Config файл** - создаётся официальным способом ✅
3. **install_bin.sh** - правильная установка бинарников ✅
4. **NDM hooks** - аналог openwrt iface hooks ✅
5. **Списки доменов** - z4r система работает ✅

---

## 🎯 ИТОГО:

**Критичных пропусков: 4**
1. check_prerequisites_openwrt (ipset, iptables-mod-nfqueue)
2. select_fwtype (определение firewall)
3. require_root (проверка прав)
4. Flow offloading (может ломать bypass)

**Остальное либо реализовано, либо не критично для Keenetic.**
