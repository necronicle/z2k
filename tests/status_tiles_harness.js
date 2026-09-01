// Прогон построения плиток дашборда С ИСПОЛНЕНИЕМ кода.
//
// Грепом это не ловится: плитка custom.d была объявлена с зашитым kind: "",
// то есть синтаксически безупречна, а на экране оказывалась без иконки и без
// цвета рядом с соседями при том же значении «Вкл» (скриншот с роутера
// 01.09.2026). Проверять надо результат построения, а не текст файла.
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

// Вырезаем ровно объявление cells внутри renderStatusGrid и исполняем его.
const m = src.match(/const cells = \[([\s\S]*?)\n {2}\];/);
if (!m) { console.log("НЕТ-БЛОКА"); process.exit(0); }

const bool = v => (v === "1" ? "Вкл" : "Выкл");
const fmtSvc = v => (v === "active" ? "работает" : v === "stopped" ? "остановлен" : "нет");

function cellsFor(s) {
  return new Function("s", "bool", "fmtSvc", `const cells = [${m[1]}\n  ]; return cells;`)(s, bool, fmtSvc);
}

const ON = {
  installed: true, service: "active",
  tunnel: { running: true },
  toggles: { game_warp: "1", auto_update: "1", customd: "1" },
};
const OFF = {
  installed: true, service: "active",
  tunnel: { running: true },
  toggles: { game_warp: "0", auto_update: "0", customd: "0" },
};

const out = [];
for (const c of cellsFor(ON)) out.push(`ON|${c.label}|${c.value}|${c.kind}`);
for (const c of cellsFor(OFF)) out.push(`OFF|${c.label}|${c.value}|${c.kind}`);
console.log(out.join("\n"));
