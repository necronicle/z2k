# z2k v2.0 - Zapret2 для Keenetic (ALPHA TEST)

Проект в активной разработке. Статус: alpha test. Возможны баги и изменения без обратной совместимости.

Если нужно максимально простое и проверенное решение, посмотрите также: https://github.com/IndeecFOX/zapret4rocket

---

## Что это

z2k - модульный установщик zapret2 для роутеров Keenetic с Entware.

Цель проекта: максимально упростить установку zapret2 на Keenetic и дать рабочий набор стратегий с автоподбором (autocircular) и поддержкой IPv6 там, где это возможно.

---

## Особенности (актуально)

- Установка zapret2 (openwrt-embedded релиз) без компиляции, с проверкой работоспособности `nfqws2`
- Генерация и применение стратегий под категории:
  - RKN (TCP/TLS)
  - YouTube TCP (TLS)
  - Googlevideo (TCP/TLS)
  - YouTube QUIC (UDP/443) по доменному списку
  - Discord (TCP/UDP) отдельными профилями
- Hostlist и autohostlist:
  - hostlist для выборочного применения (не "на весь интернет")
  - поддержка `--hostlist-auto` для TCP-профилей
- IPv6:
  - автоопределение доступности IPv6 на роутере и включение правил (iptables/ip6tables), если возможно
  - если IPv6 не поддерживается/не настроен - IPv6 правила не включаются
- Списки доменов устанавливаются автоматически (источник: zapret4rocket)

---

## Установка

### 1) Требования к прошивке Keenetic (обязательно)

Перед установкой zapret2 в веб-интерфейсе Keenetic нужно установить компоненты:

1) "Протокол IPv6"
2) "Модули ядра подсистемы Netfilter" (появляется только после выбора компонента "Протокол IPv6")

### 2) Подготовка USB и установка Entware (обязательно)

Подготовьте USB-накопитель и установите Entware по официальной инструкции Keenetic:
https://help.keenetic.com/hc/ru/articles/360021214160-%D0%A3%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D0%BA%D0%B0-%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B-%D0%BF%D0%B0%D0%BA%D0%B5%D1%82%D0%BE%D0%B2-%D1%80%D0%B5%D0%BF%D0%BE%D0%B7%D0%B8%D1%82%D0%BE%D1%80%D0%B8%D1%8F-Entware-%D0%BD%D0%B0-USB-%D0%BD%D0%B0%D0%BA%D0%BE%D0%BF%D0%B8%D1%82%D0%B5%D0%BB%D1%8C

После установки Entware выполните обновление индекса пакетов и установите зависимости:

```bash
opkg update
opkg install coreutils-sort curl grep gzip ipset iptables kmod_ndms xtables-addons_legacy
```

### 3) Установка z2k (Zapret2 для Keenetic)

```bash
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/test/z2k.sh | sh
```

---

## Что делает установщик (в общих чертах)

- Проверяет окружение (Entware, зависимости, архитектуру).
- Устанавливает zapret2 в `/opt/zapret2` и ставит init-скрипт `/opt/etc/init.d/S99zapret2`.
- Скачивает/обновляет доменные списки.
- Генерирует и применяет дефолтные стратегии с автоподбором (autocircular) для ключевых категорий.
- Включает IPv6 правила, если IPv6 реально доступен и доступен backend (ip6tables/nft).

---

## Использование

### Повторный запуск установщика

```bash
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/test/z2k.sh | sh
```

### Управление сервисом zapret2

```bash
/opt/etc/init.d/S99zapret2 start
/opt/etc/init.d/S99zapret2 stop
/opt/etc/init.d/S99zapret2 restart
/opt/etc/init.d/S99zapret2 status
```

### Обновление списков вручную

```bash
/opt/zapret2/ipset/get_config.sh
```

---

## Примечания

- Если вы используете IPv6 в сети, убедитесь что он включен в прошивке (см. требования выше). Установщик пытается включить IPv6 правила автоматически, но при отсутствии IPv6 маршрута/адреса IPv6 будет отключен.
- Если в системе нет `cron`, автообновление списков может быть недоступно - обновляйте списки вручную.

---

## Лицензия

MIT

