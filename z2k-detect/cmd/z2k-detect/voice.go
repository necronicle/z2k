package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/voiceprobe"
)

// voiceCmd меряет голосовой поток Дискорда.
//
// ОТЛИЧИЕ ОТ ОСТАЛЬНЫХ ЗАМЕРОВ: домена нет. Голосовой сервер выдаётся на
// сессию, в публичном DNS его нет, вписать человеку нечего. Поэтому адрес
// берётся из ЖИВОГО разговора — из таблицы соединений ядра, — и замер требует,
// чтобы звонок шёл прямо сейчас.
func voiceCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("voice", flag.ExitOnError)
	repeats := fs.Int("repeats", 3, "повторов на зонд; вердикт только при единогласии")
	timeout := fs.Duration("timeout", 3*time.Second, "сколько ждать ответа")
	target := fs.String("addr", "", "мерить этот адрес вместо поиска живого разговора")
	control := fs.String("control", "", "публичный сервер STUN для проверки, что UDP на канале ходит")
	asJSON := fs.Bool("json", false, "выдать результат как JSON")
	_ = fs.Parse(rest)

	res := voiceprobe.Run(ctx, voiceprobe.Options{
		Repeats: *repeats, Timeout: *timeout, Target: *target, ControlServer: *control,
	})

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(res)
		return
	}

	if res.Target != "" {
		fmt.Printf("Разговор:  %s\n", res.Target)
	}
	fmt.Printf("Вердикт:   %s — %s\n", res.Verdict, res.Reason)
	if res.Probes > 0 {
		fmt.Printf("Зондов:    %d за %s (по %d повтора)\n", res.Probes, res.Duration, res.Repeats)
	}
	if !res.Marked {
		fmt.Println("ВНИМАНИЕ:  сокет не помечен — замер прошёл через наш же обход и недостоверен")
	}
	if res.Strategy != "" {
		fmt.Printf("\nПриём:     %s\n", res.Strategy)
		fmt.Printf("           (вставлять на вкладке «Свои стратегии» в пул «Дискорд, голос»)\n")
	} else if res.Verdict == voiceprobe.VerdictBlocked {
		fmt.Printf("\nПриём:     не найдено ни одной фальшивки, которая пробивает\n")
	}
	for _, n := range res.Notes {
		fmt.Printf("\nОговорка:  %s\n", n)
	}
	if len(res.Trace) > 0 {
		fmt.Println("\nТрасса:")
		for _, s := range res.Trace {
			if s.Sent == 0 {
				fmt.Printf("  %-42s не измерено  — %s\n", s.Name, s.Note)
				continue
			}
			line := fmt.Sprintf("  %-42s %d/%d", s.Name, s.Answered, s.Sent)
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
