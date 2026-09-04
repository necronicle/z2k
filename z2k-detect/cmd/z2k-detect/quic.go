package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"

	"github.com/necronicle/z2k/z2k-detect/internal/quicprobe"
)

// quicCmd меряет, что происходит с доменом по QUIC.
//
// ОТЛИЧИЕ ОТ classify. Тот меряет функцию решения коробки на TCP-потоке: там
// есть разрез по позиции, есть RST как явная инъекция, и вердикт выносится
// двоичным поиском границы сигнатуры. В UDP нет ни того, ни другого: коробка
// молча дропает, а датаграмма атомарна. Поэтому здесь другая механика —
// сначала добывается отвечающая база, потом у коробки по одному спрашивают
// свойства, и вывод делается только из пары «контроль отвечает, зонд молчит».
//
// Команда СТАТЕЛЕСС: ничего не пишет ни в конфиг, ни в списки, ни в состояние
// ротации.
func quicCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("quic", flag.ExitOnError)
	port := fs.Int("port", 443, "порт UDP")
	repeats := fs.Int("repeats", 3, "повторов на зонд; свойство засчитывается только при единогласии")
	timeout := fs.Duration("timeout", 0, "ожидание ответа; ноль — вывести из измеренного RTT")
	parallel := fs.Int("parallel", 6, "сколько зондов держать в воздухе")
	addr := fs.String("addr", "", "слать на этот адрес вместо разрешения имени (имя остаётся в SNI)")
	asJSON := fs.Bool("json", false, "выдать результат как JSON")
	_ = fs.Parse(rest)
	if fs.NArg() < 1 {
		fatal("quic: не указан домен")
	}
	host := fs.Arg(0)
	// Человек вставляет и «домен:порт», и просто домен.
	if h, p, err := net.SplitHostPort(host); err == nil {
		host = h
		if n, err := strconv.Atoi(p); err == nil {
			*port = n
		}
	}

	res := quicprobe.Run(ctx, host, quicprobe.Options{
		Port:     *port,
		Repeats:  *repeats,
		Timeout:  *timeout,
		Parallel: *parallel,
		Addr:     *addr,
	})

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(res)
		return
	}

	fmt.Printf("Цель:     %s (%s)\n", res.Target, res.Addr)
	fmt.Printf("Вердикт:  %s — %s\n", res.Verdict, res.Reason)
	fmt.Printf("Зондов:   %d за %s (по %d повтора)\n", res.Probes, res.Duration, res.Repeats)
	if res.RTTMS > 0 {
		fmt.Printf("Отклик:   %d мс на контрольном имени\n", res.RTTMS)
	}
	printProps(res.Props)
	if res.Strategy != "" {
		// Печатаем ПРИЁМ, а не полный профиль: каркас (фильтры, окна, ротатор
		// с ключом пула) дописывает панель при вставке. Ровно так же ведёт
		// себя TCP-половина инструмента.
		fmt.Printf("\nПриём:    %s\n", res.Strategy)
		fmt.Printf("          (вставлять на вкладке «Свои стратегии» в пул QUIC —\n")
		fmt.Printf("           фильтры, окна и ротатор допишутся сами)\n")
	} else if res.Verdict == quicprobe.VerdictContent {
		fmt.Printf("\nСтрока:   не найдено приёма, который движок умеет исполнить\n")
	}
	for _, f := range res.Findings {
		fmt.Printf("\nНаходка:  %s\n", f)
	}
	for _, n := range res.Notes {
		fmt.Printf("\nОговорка: %s\n", n)
	}
	if len(res.Trace) > 0 {
		fmt.Println("\nТрасса:")
		for _, s := range res.Trace {
			// Несобравшийся зонд не показываем как «0 из 3»: ноль ответов и
			// отсутствие замера — разные вещи, и путать их в трассе нельзя,
			// её читает поддержка.
			if s.NotBuilt > 0 || s.Sent == 0 {
				fmt.Printf("  %-46s не измерено", s.Name)
				if s.Note != "" {
					fmt.Printf("  — %s", s.Note)
				}
				fmt.Println()
				continue
			}
			line := fmt.Sprintf("  %-46s %d/%d", s.Name, s.Answered, s.Sent)
			if s.MS > 0 {
				line += fmt.Sprintf(" за %d мс", s.MS)
			}
			if s.Note != "" {
				line += "  — " + s.Note
			}
			fmt.Println(line)
		}
	}
}

func printProps(p quicprobe.Properties) {
	fmt.Println("Свойства коробки:")
	if p.ResidualBlocking != nil {
		if *p.ResidualBlocking {
			fmt.Printf("  %-28s есть — после срабатывания глушит и безобидные датаграммы\n",
				"остаточная блокировка:")
		} else {
			fmt.Printf("  %-28s нет — срабатывание следа не оставляет\n", "остаточная блокировка:")
		}
	}
	// Дальше — про ПРИЁМЫ, а не про устройство коробки. «Не помогло» не значит
	// «коробка умеет собирать»: тишина в UDP многозначна, и выводить из неё
	// механику нельзя. Механика попадает в находки — и только по проходу.
	tech := func(name string, v *bool) {
		if v == nil {
			return
		}
		if *v {
			fmt.Printf("  %-28s ПРОХОДИТ\n", name+":")
		} else {
			fmt.Printf("  %-28s не помогает\n", name+":")
		}
	}
	tech("мусор перед Initial", p.JunkAheadHelps)
	tech("приветствие по кадрам", p.SplitCryptoHelps)
	tech("приветствие по датаграммам", p.SplitDatagramsHelps)
	tech("вторая версия QUIC", p.VersionTwoHelps)
	tech("погашен фиксированный бит", p.ClearFixedBitHelps)
	tech("низкий исходный порт", p.LowSourcePortHelps)
	if p.ServerTTLIn > 0 {
		fmt.Printf("  %-28s %d (сырой, в расстояние не пересчитан)\n",
			"TTL ответа сервера:", p.ServerTTLIn)
	}
	if p.FragSurvives != nil {
		if *p.FragSurvives {
			fmt.Printf("  %-28s доходят\n", "IP-фрагменты на канале:")
		} else {
			fmt.Printf("  %-28s НЕ доходят — семейство ipfrag тут неприменимо\n",
				"IP-фрагменты на канале:")
		}
	}
	if p.FragArm != "" {
		fmt.Printf("  %-28s %s\n", "помогает фрагментация:", p.FragArm)
	}
	if p.FakeAhead != "" {
		line := p.FakeAhead
		if p.FakeRepeats > 0 {
			line += fmt.Sprintf(", копий %d", p.FakeRepeats)
		}
		if p.FakeTTL > 0 {
			line += fmt.Sprintf(", TTL %d", p.FakeTTL)
		}
		fmt.Printf("  %-28s %s\n", "помогает фальшивка:", line)
	}
	if p.UDPLen > 0 {
		fmt.Printf("  %-28s +%d байт\n", "помогает добивка длины:", p.UDPLen)
	}
}
