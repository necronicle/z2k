# Сравнение init скриптов: Официальный vs Наш

## Официальный init.d/openwrt/zapret2

### ✅ Преимущества:

1. **procd integration** - правильный process manager для OpenWrt
   ```bash
   procd_open_instance
   procd_set_param command $2 $3
   procd_set_param pidfile $PIDDIR/${DAEMONBASE}_$1.pid
   procd_close_instance
   ```

2. **Source всех модулей common/**
   ```bash
   . "$ZAPRET_BASE/common/base.sh"
   . "$ZAPRET_BASE/common/fwtype.sh"
   . "$ZAPRET_BASE/common/ipt.sh"
   . "$ZAPRET_BASE/common/nft.sh"
   . "$ZAPRET_BASE/common/linux_fw.sh"
   . "$ZAPRET_BASE/common/linux_daemons.sh"
   ```

3. **Читает config** - все настройки из файла
   ```bash
   ZAPRET_CONFIG=${ZAPRET_CONFIG:-"$ZAPRET_RW/config"}
   . "$ZAPRET_CONFIG"
   ```

4. **Разделение firewall и daemons**
   - `start_daemons` - запуск nfqws2
   - `start_fw` - настройка iptables/nftables
   - Можно рестартовать отдельно!

5. **Поддержка nftables И iptables**
   - Автоопределение через `linux_fwtype`
   - Функции из common/nft.sh и common/ipt.sh

6. **Flow offloading exemption**
   - Корректно исключает трафик zapret из offloading
   - Поддержка hardware/software offloading

7. **Автоопределение WAN интерфейсов**
   ```bash
   network_find_wan4_all
   network_find_wan6_all
   ```

8. **Custom scripts support**
   ```bash
   custom_runner zapret_custom_daemons
   ```

9. **Правильное управление процессами**
   - PID files в /var/run/
   - Graceful shutdown через procd

---

## Наш init скрипт /opt/etc/init.d/S99zapret2

### ❌ Проблемы:

1. **Примитивное управление процессами**
   ```bash
   killall nfqws2 2>/dev/null  # брутально убивает все
   sleep 1
   ```

2. **НЕ использует модули common/**
   - Дублируем логику iptables вручную
   - Нет доступа к утилитам из base.sh

3. **Hardcoded стратегии в init скрипте**
   ```bash
   YOUTUBE_TCP_TCP="--filter-tcp=443..."
   RKN_TCP="--filter-tcp=443..."
   ```
   Вместо чтения из config файла!

4. **Нет разделения firewall/daemons**
   - start() делает всё сразу
   - Нельзя перезапустить только firewall

5. **Только iptables**
   - Нет поддержки nftables
   - Нет автоопределения FWTYPE

6. **Ручное управление iptables**
   ```bash
   iptables -t mangle -N ZAPRET
   iptables -t mangle -A FORWARD -j ZAPRET
   ```
   Вместо использования функций из common/ipt.sh

7. **Нет PID файлов**
   - Проверка через `pgrep -f "$NFQWS"`
   - Нет graceful shutdown

8. **Нет поддержки custom scripts**

---

## Почему наш init хуже:

| Аспект | Официальный | Наш |
|--------|-------------|-----|
| Process management | procd (правильно) | killall (грубо) |
| Модули common/ | ✅ Использует | ❌ Нет |
| Config файл | ✅ Читает | ❌ Hardcoded |
| Firewall/Daemons | ✅ Раздельно | ❌ Вместе |
| nftables/iptables | ✅ Оба | ❌ Только iptables |
| Flow offloading | ✅ Корректный exempt | ❌ Нет |
| PID files | ✅ Да | ❌ Нет |
| Custom scripts | ✅ Да | ❌ Нет |
| WAN detection | ✅ Авто | ❌ Hardcoded |

---

## НО! Keenetic != OpenWrt

### Различия платформ:

| Компонент | OpenWrt | Keenetic |
|-----------|---------|----------|
| Process manager | procd | runit/sysv |
| Network detection | /lib/functions/network.sh | NDM netctl |
| Firewall | fw3/fw4 | NDM iptables |
| Init hooks | /etc/init.d/ + procd | /opt/etc/init.d/ + S99 prefix |
| Firewall hooks | fw3 include | /opt/etc/ndm/netfilter.d/ |
| Config | /etc/config/zapret2 | /opt/etc/zapret2/config |

### Что НЕ работает на Keenetic:

1. ❌ `procd_*` функции - нет procd
2. ❌ `network_find_wan*` - нет /lib/functions/network.sh
3. ❌ `openwrt_fw3_integration` - нет fw3
4. ❌ `/etc/rc.common` - другой init system

---

## Правильный подход для Keenetic:

### Адаптировать официальный init скрипт:

```bash
#!/bin/sh
# /opt/etc/init.d/S99zapret2
# Адаптация официального init.d/openwrt/zapret2 для Keenetic

ZAPRET_BASE=/opt/zapret2
ZAPRET_CONFIG="$ZAPRET_BASE/config"

# Source модули common/ (работает и на Keenetic!)
. "$ZAPRET_BASE/common/base.sh"
. "$ZAPRET_BASE/common/fwtype.sh"
. "$ZAPRET_BASE/common/linux_daemons.sh"
. "$ZAPRET_BASE/common/ipt.sh"
. "$ZAPRET_BASE/common/custom.sh"

# Читать config (вместо hardcoded стратегий)
. "$ZAPRET_CONFIG"

# Использовать функции из common/linux_daemons.sh
start_daemons() {
    standard_mode_daemons 1
    custom_runner zapret_custom_daemons 1
}

stop_daemons() {
    stop_nfqws
}

# Использовать функции из common/ipt.sh для firewall
start_fw() {
    zapret_apply_firewall  # из common/linux_fw.sh
}

stop_fw() {
    zapret_unapply_firewall
}

start() {
    start_fw
    start_daemons
}

stop() {
    stop_daemons
    stop_fw
}
```

### Преимущества адаптированного подхода:

✅ **Используем проверенный код** из common/
✅ **Config файл** вместо hardcoded стратегий
✅ **Разделение firewall/daemons**
✅ **Поддержка custom scripts**
✅ **PID файлы** через функции linux_daemons.sh
✅ **Совместимость с официальными обновлениями**

### Что адаптировать:

1. Убрать procd → использовать обычный daemon запуск
2. Убрать network.sh → хардкод WAN или через ndm
3. Убрать fw3 integration → использовать напрямую zapret_apply_firewall
4. Сохранить структуру с functions файлом

---

## Вывод:

Наш init скрипт **ХУЖЕ** официального, потому что:
- Дублирует логику вместо использования common/
- Hardcoded стратегии вместо config файла
- Нет разделения firewall/daemons
- Грубое управление процессами

**Правильно:** Адаптировать официальный init скрипт для Keenetic, сохранив использование модулей common/ и config файла.
