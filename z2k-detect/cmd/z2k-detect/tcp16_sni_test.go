package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Имя мишени обязано доезжать до пробы.
//
// У эталонного dpi-detector, с которым мы обязаны совпадать, семь мишеней несут
// поле sni: без имени они отвечают чужой заглушкой, и обрыв по объёму на них не
// наступает никогда. При переносе их данных к себе колонка была потеряна — мы
// ходили туда по голому адресу и меряли не то, что меряют они.
func TestTargetsCarrySNI(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "targets.txt")
	body := "# комментарий\n" +
		"FST-03\t54113\t*\tFastly GitHub 108\t185.199.108.133\t443\trelease-assets.githubusercontent.com\n" +
		"HE-01\t24940\t*\tHetzner\t91.98.156.82\t443\t\n" +
		"OLD-01\t1234\t*\tСтарыйФормат\t192.0.2.1\t443\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	tgs, err := loadTargets(p, "", false, 0)
	if err != nil {
		t.Fatalf("не прочитались мишени: %v", err)
	}
	if len(tgs) != 3 {
		t.Fatalf("ждал 3 мишени, получил %d", len(tgs))
	}

	if tgs[0].SNI != "release-assets.githubusercontent.com" {
		t.Fatalf("имя не прочитано: %q", tgs[0].SNI)
	}
	if tgs[1].SNI != "" {
		t.Fatalf("у мишени без имени оно откуда-то взялось: %q", tgs[1].SNI)
	}
	// Строки прежнего формата, без седьмой колонки, обязаны читаться как были:
	// файл у людей обновляется отдельно от бинарника.
	if tgs[2].SNI != "" || tgs[2].IP != "192.0.2.1" {
		t.Fatalf("старый формат сломан: %+v", tgs[2])
	}
}

// И то же на ПОСТАВЛЯЕМОМ файле: семь имён должны быть на месте, иначе колонка
// есть, а данных в ней нет.
func TestShippedTargetsHaveSevenNames(t *testing.T) {
	p := filepath.Join("..", "..", "..", "files", "lists", "tcp16_targets.txt")
	if _, err := os.Stat(p); err != nil {
		t.Skipf("нет поставляемого файла: %v", err)
	}
	tgs, err := loadTargets(p, "", false, 0)
	if err != nil {
		t.Fatalf("не прочитался: %v", err)
	}
	n := 0
	for _, x := range tgs {
		if x.SNI != "" {
			n++
		}
	}
	if n != 7 {
		t.Fatalf("мишеней с именем %d, а у эталона 7", n)
	}
}
