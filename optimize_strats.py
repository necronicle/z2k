#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Оптимизация стратегий DPI bypass - отбор уникальных с максимальным охватом техник
"""

import re
from collections import defaultdict

def parse_strategy(strat):
    """Извлечь ключевые параметры стратегии"""
    params = {}

    # Основная функция
    if 'multidisorder' in strat:
        params['type'] = 'multidisorder'
    elif 'multisplit' in strat:
        params['type'] = 'multisplit'
    elif 'fakedsplit' in strat:
        params['type'] = 'fakedsplit'
    elif 'syndata' in strat:
        params['type'] = 'syndata'
    elif 'fake' in strat:
        params['type'] = 'fake'
    elif 'urp=' in strat:
        params['type'] = 'oob'
    elif 'tcpseg' in strat:
        params['type'] = 'tcpseg'
    elif 'disorder_after' in strat:
        params['type'] = 'disorder_after'
    else:
        params['type'] = 'other'

    # Позиция
    pos_match = re.search(r'pos=([^,\)]+)', strat)
    if pos_match:
        params['pos'] = pos_match.group(1)

    # Параметры TCP/IP
    params['tcp_md5'] = 'tcp_md5' in strat
    params['tcp_seq'] = 'tcp_seq' in strat
    params['ip_ttl'] = 'ip_ttl' in strat
    params['tcp_timestamps'] = 'tcp_timestamps' in strat
    params['tcp_fooling'] = 'tcp_fooling' in strat

    # Blob
    if 'blob=fake_default_tls' in strat:
        params['blob'] = 'fake_default_tls'
    elif 'blob=0x00000000' in strat:
        params['blob'] = '0x00000000'
    elif 'blob=' in strat:
        params['blob'] = 'other'

    # urp значение
    urp_match = re.search(r'urp=(\d+)', strat)
    if urp_match:
        params['urp'] = urp_match.group(1)

    return params

def optimize_strategies(input_file, output_file):
    """Оптимизировать стратегии"""

    # Читаем все стратегии
    with open(input_file, 'r', encoding='utf-8') as f:
        all_strats = [line.strip() for line in f if line.strip()]

    print(f"Всего стратегий: {len(all_strats)}")

    # Группируем по типам
    categorized = defaultdict(list)
    for strat in all_strats:
        params = parse_strategy(strat)
        categorized[params['type']].append((strat, params))

    print("\nКатегории:")
    for cat, items in sorted(categorized.items()):
        print(f"  {cat}: {len(items)}")

    # Отбираем оптимальные стратегии
    selected = []

    # 1. OOB стратегии (urp=X) - оставить все 3, они уникальны
    if 'oob' in categorized:
        print(f"\n[OOB] Оставляем все {len(categorized['oob'])} стратегии")
        selected.extend([s[0] for s in categorized['oob']])

    # 2. MULTIDISORDER - оставить ключевые позиции
    if 'multidisorder' in categorized:
        positions_to_keep = {'2', 'sniext+1', 'midsld', '1', '3', 'host', 'sniext'}
        multidisorder_selected = []
        seen_positions = set()

        for strat, params in categorized['multidisorder']:
            pos = params.get('pos', '')
            if pos in positions_to_keep and pos not in seen_positions:
                multidisorder_selected.append(strat)
                seen_positions.add(pos)

        print(f"[MULTIDISORDER] Отобрано {len(multidisorder_selected)} из {len(categorized['multidisorder'])}")
        selected.extend(multidisorder_selected)

    # 3. MULTISPLIT - аналогично multidisorder, но больше вариаций
    if 'multisplit' in categorized:
        # Группируем по комбинациям параметров
        multisplit_groups = defaultdict(list)

        for strat, params in categorized['multisplit']:
            # Ключ: позиция + TCP/IP параметры
            key = (
                params.get('pos', ''),
                params.get('tcp_md5', False),
                params.get('tcp_seq', False),
                params.get('ip_ttl', False),
                params.get('tcp_timestamps', False),
                params.get('tcp_fooling', False)
            )
            multisplit_groups[key].append(strat)

        # Важные позиции для multisplit
        priority_positions = ['2', 'sniext+1', 'midsld', '1', '3', 'host', 'sniext', 'host+1']

        # Важные комбинации параметров
        priority_params = [
            (False, False, False, False, False),  # базовая
            (True, False, False, False, False),   # tcp_md5
            (False, True, False, False, False),   # tcp_seq
            (False, False, True, False, False),   # ip_ttl
            (False, False, False, True, False),   # tcp_timestamps
            (False, False, False, False, True),   # tcp_fooling
        ]

        multisplit_selected = []
        seen_keys = set()

        # Сначала отбираем приоритетные комбинации
        for pos in priority_positions:
            for params in priority_params:
                key = (pos,) + params
                if key in multisplit_groups and key not in seen_keys:
                    multisplit_selected.append(multisplit_groups[key][0])
                    seen_keys.add(key)

        # Добавляем еще несколько уникальных комбинаций
        for key, strats in multisplit_groups.items():
            if key not in seen_keys and len(multisplit_selected) < 50:
                multisplit_selected.append(strats[0])
                seen_keys.add(key)

        print(f"[MULTISPLIT] Отобрано {len(multisplit_selected)} из {len(categorized['multisplit'])}")
        selected.extend(multisplit_selected)

    # 4. FAKEDSPLIT - много комбинаций, отбираем представителей каждой техники
    if 'fakedsplit' in categorized:
        fakedsplit_groups = defaultdict(list)

        for strat, params in categorized['fakedsplit']:
            # Ключ: позиция + TCP/IP параметры
            key = (
                params.get('pos', ''),
                params.get('tcp_md5', False),
                params.get('tcp_seq', False),
                params.get('ip_ttl', False),
                params.get('tcp_timestamps', False),
                params.get('tcp_fooling', False)
            )
            fakedsplit_groups[key].append(strat)

        # Приоритетные позиции
        priority_positions = ['2', 'sniext+1', 'midsld', '1', '3', 'host', 'sniext']

        # Приоритетные параметры
        priority_params = [
            (False, False, False, False, False),
            (True, False, False, False, False),
            (False, True, False, False, False),
            (False, False, True, False, False),
            (False, False, False, True, False),
            (False, False, False, False, True),
            (True, True, False, False, False),
            (False, True, True, False, False),
        ]

        fakedsplit_selected = []
        seen_keys = set()

        # Отбираем приоритетные комбинации
        for pos in priority_positions:
            for params in priority_params:
                key = (pos,) + params
                if key in fakedsplit_groups and key not in seen_keys:
                    fakedsplit_selected.append(fakedsplit_groups[key][0])
                    seen_keys.add(key)

        # Добавляем еще уникальные
        for key, strats in fakedsplit_groups.items():
            if key not in seen_keys and len(fakedsplit_selected) < 60:
                fakedsplit_selected.append(strats[0])
                seen_keys.add(key)

        print(f"[FAKEDSPLIT] Отобрано {len(fakedsplit_selected)} из {len(categorized['fakedsplit'])}")
        selected.extend(fakedsplit_selected)

    # 5. FAKE стратегии - уменьшить дубликаты
    if 'fake' in categorized:
        fake_groups = defaultdict(list)

        for strat, params in categorized['fake']:
            key = (
                params.get('blob', ''),
                params.get('tcp_md5', False),
                params.get('tcp_seq', False),
                params.get('ip_ttl', False),
                params.get('tcp_timestamps', False),
                params.get('tcp_fooling', False)
            )
            fake_groups[key].append(strat)

        fake_selected = []
        # Берем по одному представителю каждой уникальной комбинации
        for strats in fake_groups.values():
            fake_selected.append(strats[0])

        print(f"[FAKE] Отобрано {len(fake_selected)} из {len(categorized['fake'])}")
        selected.extend(fake_selected)

    # 6. SYNDATA - оставить основные варианты
    if 'syndata' in categorized:
        print(f"[SYNDATA] Оставляем все {len(categorized['syndata'])} стратегии")
        selected.extend([s[0] for s in categorized['syndata']])

    # 7. TCPSEG - оставить все
    if 'tcpseg' in categorized:
        print(f"[TCPSEG] Оставляем все {len(categorized['tcpseg'])} стратегии")
        selected.extend([s[0] for s in categorized['tcpseg']])

    # 8. DISORDER_AFTER - оставить все
    if 'disorder_after' in categorized:
        print(f"[DISORDER_AFTER] Оставляем все {len(categorized['disorder_after'])} стратегии")
        selected.extend([s[0] for s in categorized['disorder_after']])

    # 9. OTHER - оставить все
    if 'other' in categorized:
        print(f"[OTHER] Оставляем все {len(categorized['other'])} стратегии")
        selected.extend([s[0] for s in categorized['other']])

    # Записываем результат
    with open(output_file, 'w', encoding='utf-8') as f:
        for strat in selected:
            f.write(strat + '\n')

    print(f"\n{'='*60}")
    print(f"Итого отобрано: {len(selected)} стратегий из {len(all_strats)}")
    print(f"Сокращение: {len(all_strats) - len(selected)} стратегий ({100 * (1 - len(selected)/len(all_strats)):.1f}%)")
    print(f"Результат сохранен в: {output_file}")

if __name__ == '__main__':
    optimize_strategies(
        r'E:\Zapret2-keenetik\strats_new2.txt',
        r'E:\Zapret2-keenetik\strats_optimized.txt'
    )
