# Анализ функций install_easy.sh для использования в z2k

## Функции которые МОЖНО использовать напрямую:

### ✅ check_prerequisites_openwrt
**Что делает:**
- Проверяет наличие пакетов: curl, iptables, ipset, iptables-mod-nfqueue
- Устанавливает отсутствующие через opkg
- Предлагает GNU gzip/sort вместо busybox (для производительности)

**Можем использовать:** ДА
**Как:** Source common/installer.sh и вызвать напрямую

```bash
. "$ZAPRET2_DIR/common/installer.sh"
check_prerequisites_openwrt
```

---

### ✅ install_binaries (через install_bin.sh)
**Что делает:**
- Автоматически определяет архитектуру (ELF header, bash test)
- Валидирует бинарники запуском ip2net
- Создаёт симлинки для nfqws2, ip2net, mdig

**Можем использовать:** ДА (уже используем в новом коде)

---

### ✅ check_bins
**Что делает:**
- Проверяет наличие binaries/ директории
- Вызывает install_bin.sh getarch для определения архитектуры
- Компилирует из исходников если нет подходящих бинарников

**Можем использовать:** ДА, но нам не нужна компиляция

---

### ✅ check_dns
**Что делает:**
- Проверяет доступность DNS через nslookup w3.org

**Можем использовать:** ДА

---

### ⚠️ download_list
**Что делает:**
- Запускает ipset/get_config.sh
- Скачивает списки antifilter/antizapret/reestr

**Можем использовать:** НЕТ
**Почему:** У нас своя система доменов из zapret4rocket (z4r)
**Альтернатива:** Наша функция download_domain_lists() из lib/config.sh

---

### ❌ install_sysv_init
**Что делает:**
- Создаёт симлинк /etc/init.d/zapret2 -> $INIT_SCRIPT_SRC
- Вызывает enable для автозапуска

**Можем использовать:** НЕТ
**Почему:** На Keenetic нет команды enable для SysV init
**Альтернатива:** Наш init скрипт в /opt/etc/init.d/S99zapret2 (автозапуск по S99 префиксу)

---

### ❌ install_openwrt_firewall
**Что делает:**
- Интегрируется с fw3 (firewall3 в OpenWrt)
- Создаёт /etc/firewall.zapret2
- Добавляет include в /etc/config/firewall

**Можем использовать:** НЕТ
**Почему:** На Keenetic нет fw3, используется ndm/netfilter.d hooks
**Альтернатива:** Наш hook /opt/etc/ndm/netfilter.d/000-zapret2.sh

---

### ⚠️ ask_config
**Что делает:**
- Интерактивный выбор режима (nfqws/tpws)
- Выбор портов, опций desync
- Выбор фильтрации (ipset/hostlist/autohostlist)

**Можем использовать:** НЕТ (интерактивный)
**Альтернатива:** Автоматическая конфигурация через наши стратегии

---

## Модули common/ которые полезны:

### ✅ common/base.sh
- `exists()` - проверка наличия команды
- `get_dir_inode()` - сравнение директорий
- `dir_is_not_empty()` - проверка пустоты
- `get_free_space_mb()` - свободное место
- `get_ram_mb()` - RAM

**Использование:** Source и использовать утилиты

---

### ✅ common/installer.sh
- `check_package_exists_openwrt()` - проверка opkg пакета
- `check_packages_openwrt()` - проверка списка пакетов
- `write_config_var()` - запись переменных в config
- `parse_var_checked()` - чтение переменных из config

**Использование:** Source для работы с пакетами и конфигом

---

### ⚠️ common/dialog.sh
- `ask_yes_no()` - интерактивные вопросы
- `ask_list()` - выбор из списка

**Использование:** НЕТ (интерактивный, у нас автоматическая установка)

---

### ❌ common/ipt.sh
- `ipt()` - обёртки для iptables
- Много функций для настройки ipset, nfqueue

**Использование:** НЕТ (у нас свой init скрипт с iptables правилами)

---

## Итоговая стратегия для z2k:

### ЧТО ИСПОЛЬЗОВАТЬ из официальных скриптов:

1. **install_bin.sh целиком** - установка бинарников ✅
2. **check_prerequisites_openwrt** - проверка/установка пакетов ✅
3. **check_dns** - проверка DNS ✅
4. **Утилиты из common/base.sh** - exists(), get_ram_mb() и др. ✅
5. **Утилиты из common/installer.sh** - check_packages_openwrt() ✅

### ЧТО НЕ ИСПОЛЬЗОВАТЬ:

1. **download_list** - у нас z4r домены ❌
2. **install_sysv_init** - другой путь init скрипта ❌
3. **install_openwrt_firewall** - у нас ndm hooks ❌
4. **ask_config** - интерактивный режим ❌

### ЧТО ОСТАВИТЬ СВОЁ:

1. **Init скрипт** - /opt/etc/init.d/S99zapret2 с нашей логикой
2. **Домены** - download_domain_lists() из z4r
3. **Стратегии** - наша система multi-profile
4. **NDM hooks** - /opt/etc/ndm/netfilter.d/000-zapret2.sh

---

## Гибридный подход (рекомендуется):

```bash
step_install_zapret2() {
    # 1. Скачать полный релиз OpenWrt embedded
    download_zapret2_openwrt_release

    # 2. Source официальные модули
    . "$ZAPRET2_DIR/common/base.sh"
    . "$ZAPRET2_DIR/common/installer.sh"

    # 3. Использовать официальные функции
    check_bins                          # ✅
    install_binaries                    # ✅ (вызывает install_bin.sh)
    check_dns                          # ✅
    check_prerequisites_openwrt        # ✅

    # 4. НО использовать СВОИ функции для:
    download_domain_lists              # z4r домены
    create_keenetic_init_script        # наш init скрипт
    install_netfilter_hook             # ndm hook
    apply_default_strategies           # наши стратегии
}
```

Этот подход даёт нам:
- ✅ Надёжную установку бинарников (проверенный код)
- ✅ Автоматическую проверку зависимостей
- ✅ Доступ к утилитам common/
- ✅ Гибкость для Keenetic-специфичных частей
