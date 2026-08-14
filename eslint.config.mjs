// Статическая проверка JavaScript. Единственный язык в репозитории, у которого
// её не было вовсе: у Go есть vet и gofmt, у shell — shellcheck, у Lua —
// luacheck, у workflow-файлов — actionlint, а у 4262 строк вебпанели не было
// ничего. Правили их вслепую.
//
// НАБОР ПРАВИЛ ПОДБИРАЛСЯ ПОД КОНКРЕТНЫЕ ГРАБЛИ, а не «включить рекомендованное».
// Стиль не проверяется намеренно: форматирование здесь никого не кусало, а
// шумный линтер перестают читать. Оставлено то, что ломает панель у человека.
//
// Главная цель — `no-undef`. Она и есть страховка под будущее разбиение
// монолита на файлы: перенос функции через границу файла ломается именно
// висячей ссылкой, и без линтера это заметит не CI, а человек, у которого
// перестал открываться раздел.

import js from "@eslint/js";
import globals from "globals";

export default [
  {
    // Фронтенд панели: браузер, один <script>, без модулей и без сборки —
    // так задумано, панель обязана открываться на роутере без интернета.
    files: ["webpanel/www/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: { ...globals.browser },
    },
    rules: {
      ...js.configs.recommended.rules,

      // --- то, ради чего всё затевалось ---------------------------------
      "no-undef": "error",
      "no-unused-vars": ["error", {
        args: "none",
        // Пойманное и намеренно проигнорированное исключение пишется как
        // `catch (_)` — это принятый в файле приём, не забытая переменная.
        caughtErrors: "none",
        varsIgnorePattern: "^_",
      }],

      // --- то, что уже кусалось или кусается в похожем коде --------------
      // Гонка «прочитал → await → записал»: ровно та форма, из-за которой
      // ответ старого запроса перезаписывал свежий (лечилось _stale/seq).
      //
      // allowProperties отключает жалобы на `btn.disabled = false` после await.
      // Это не гонка: btn — локальная константа, а запись в свойство и есть
      // цель. Таких мест 17 из 18, и с ними правило превращается в шум,
      // который перестают читать. Остаются жалобы на ПЕРЕМЕННЫЕ — а вот там
      // это настоящая гонка, ровно та, что уже лечилась метками _stale/seq.
      "require-atomic-updates": ["error", { allowProperties: true }],
      // async-функция как исполнитель промиса — её отказ теряется молча.
      "no-async-promise-executor": "error",
      // no-await-in-loop НЕ включаем: все четыре места — это опрос задачи с
      // паузой, где последовательность и есть смысл. Правило дало бы четыре
      // вечных предупреждения, а линтер с вечными предупреждениями читать
      // перестают.
      // Промис, брошенный без обработки, оставляет кнопку «в процессе».
      "no-promise-executor-return": "error",

      // Пустой catch — принятый в файле способ сказать «исключение поймано и
      // намеренно проигнорировано» (тело не JSON, буфер обмена недоступен).
      // Пустые блоки ДРУГИХ видов остаются ошибкой.
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-fallthrough": "error",
      "no-dupe-keys": "error",
      "no-dupe-else-if": "error",
      "no-duplicate-case": "error",
      "no-unsafe-negation": "error",
      "no-unreachable": "error",
      "no-constant-condition": ["error", { checkLoops: false }],
      "no-self-compare": "error",
      "no-template-curly-in-string": "warn",
      "valid-typeof": "error",
      eqeqeq: "off", // стиль, не ловим
    },
  },
  {
    // Обвязки тестов исполняют app.js в node с поддельным DOM — у них другая
    // среда и другие глобальные.
    files: ["tests/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: { ...globals.node },
    },
    rules: {
      ...js.configs.recommended.rules,
      "no-undef": "error",
      "no-unused-vars": ["error", { args: "none", caughtErrors: "none", varsIgnorePattern: "^_" }],
    },
  },
];
