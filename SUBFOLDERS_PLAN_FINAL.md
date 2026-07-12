# Вложенные папки в notes.nvim — финальный план

## Context

Сейчас плагин поддерживает папки **только на один уровень** (`scan()` в `picker.lua` обходит
каталог на одну ступень вглубь; `state.folders` — плоский список `{ name, folder }`; окно Folders
рендерит одноуровневое дерево). Задача — разрешить произвольную вложенность папок, сохранив всю
текущую логику: сортировку по свежести редактирования, merge-модель конфликтов, фоновую git-синхронизацию.

Исходный черновик — `SUBFOLDERS_PLAN.md`. По итогам уточнения приняты решения:

1. **Модель Folders — drill-down (по одному уровню).** Окно Folders показывает: строку 1 = текущая
   папка (`main_folder`), ниже — только её **непосредственные** подпапки. Клавиша `o` входит в
   подпапку под курсором, а на строке 1 — поднимает на уровень вверх.
2. **Перенос целых папок (вырезать `x` / вставить `p`) — НЕ входит в этот этап** (раздел 6 черновика
   отложен). Заметки по-прежнему переносятся через `x`/`p`. `cut_folder` в state не добавляем.
3. **`a` (create_folder) создаёт подпапку внутри текущего отображаемого уровня** (`main_folder`),
   независимо от строки под курсором.

Ключевое ограничение: не сломать существующие тесты и merge-синхронизацию.

---

## 1. State (`lua/notes/init.lua`)

Добавить в `M.state` одно поле:
- `main_folder = nil` — относительный путь текущего отображаемого уровня (`"Work"`,
  `"Work/Projects"`); `nil` = корень `Notes`. `current_folder` остаётся **выбранной** папкой
  (строка под курсором — может быть `main_folder` или один из его детей).

Сбросить `main_folder = nil` в двух местах, где уже сбрасываются остальные поля:
- `M.is_open()` (self-heal, `init.lua`).
- `M.close()` (`ui.lua`).

`cut_folder` **не добавляем** (перенос папок отложен).

## 2. Config (`lua/notes/init.lua`)

Добавить в `M.config.keys` новую привязку:
- `change_folder = 'o'` — drill-навигация в колонке Folders (вход в подпапку / выход на уровень вверх).

## 3. Рекурсивное сканирование и сортировка (`lua/notes/picker.lua`)

### `M.scan()` — сделать рекурсивным
Заменить одноуровневый обход (текущие строки ~105-119) на рекурсивный обход `vim.fs.dir`,
пропуская записи с префиксом `.` (исключает `.git`/`.gitkeep`):
- Накапливать **все** относительные пути папок любой глубины в `real` (`"Work"`,
  `"Work/Projects"`) — включая пустые (нужны для навигации/валидации).
- Для каждого файла складывать в `notes_all` запись `{ file, folder, title, empty, mtime }`, где
  `folder` = относительный путь папки (`""` для корня, `"Work/Projects"` для вложенной).
- Сортировка `notes_all` — без изменений (empty-first, затем mtime desc).
- Список всех папок (`real`) сохранить в модуль-локальную переменную (напр. `all_folders`),
  чтобы `build_folders()` строил из неё видимые строки. В документируемый `state` не выносим.

### Рекурсивная свежесть папки
Хелпер `folder_recursive_mtime(folder_rel) -> mtime, has_note`: максимальный `mtime` среди заметок
в самой папке **и всех её потомках** (`n.folder == folder_rel` или
`n.folder:sub(1, #folder_rel + 1) == folder_rel .. '/'`); если заметок нет нигде в поддереве —
`vim.uv.fs_stat(dir .. '/' .. folder_rel).mtime.sec` (mtime самого каталога, чтобы новая пустая
папка всплывала наверх). Сохранить строгий детерминированный тай-брейк как сейчас: свежесть →
наличие заметки в поддереве → имя (иначе нестабильный `table.sort` даёт мигание).

### `build_folders()` — строит видимые строки из `main_folder`
Новый шаг (вызывается в `populate()` после `scan()` + `validate_folder()`), формирует
`state.folders` как массив `{ name, folder, is_main }`:
- Строка 1 (`is_main = true`): `folder = main_folder` (nil для корня).
- Далее — **непосредственные** дети `main_folder`: из `all_folders` берём пути, у которых после
  префикса `main_folder .. '/'` (или без префикса на корне) **нет** дальнейшего `/`. `folder` =
  полный относительный путь ребёнка, `name` = leaf-имя (`rel:match('[^/]+$')`).
- Детей сортировать по `folder_recursive_mtime` (desc) с тем же тай-брейком.

### `filter()` — без изменений
`target = current_folder or ''`; точное совпадение `n.folder == target` (только прямые заметки
выбранной папки; вложенные видны после drill-in). Это осознанно сохраняет drill-down-семантику.

### `render_folders()` — рендер drill-down
- Строка 1 (main): корень → `Notes/`; вложенный уровень → `Notes/<main_folder> ..`, где `..` —
  визуальный хинт «`o` = вверх». Подсветка `NotesDirActive`, если `folders[1].folder == current_folder`.
- Дети: одноуровневый список с префиксами `├─`/`└─` + `name .. '/'` (как сейчас — глубоких отступов
  не нужно, показываем только один уровень). Активная строка (`folder == current_folder`) → `NotesDirActive`.
- **Рекурсивная подсветка конфликтов:** строка папки (main или ребёнок) подсвечивается
  `NotesConflict`, если конфликтна любая заметка в её **поддереве** (см. рекурсивный `folder_has_conflict`).
  Механика extmark'а (`hl_group`, `hl_mode='combine'`, priority 300) — без изменений.
- Заметка про ширину: длинные пути (`Notes/Work/Projects ..`) обрезаются шириной колонки
  (`folders_width`, `winfixwidth`). Приемлемо; усечение — опциональная косметика, вне scope.

## 4. Навигация `o` (`M.change_folder()` — новая, `picker.lua`)

- `f = selected_folder()`; если nil — выход.
- Если `f.is_main`:
  - `main_folder ~= nil`: подняться на уровень вверх — `parent = main_folder:match('^(.*)/[^/]+$')`
    (nil при выходе в корень). `main_folder = parent`, `current_folder = parent`.
  - `main_folder == nil` (уже корень): no-op.
- Иначе (ребёнок): войти внутрь — `main_folder = f.folder`, `current_folder = f.folder`.
- `M.populate()`, затем поставить курсор `folders_win` на строку 1.
  (Сработавший `CursorMoved → select_folder` выставит `current_folder = folders[1].folder` —
  согласованно с только что заданным значением.)

Привязать в `attach_folders(buf)`: `map(keys.change_folder, M.change_folder, ...)`.

## 5. Валидация (`validate_folder()`, `picker.lua`)

Заменить обход `state.folders` (который теперь показывает лишь один уровень) на проверку по диску:
```lua
local function validate_folder()
  local st = state()
  local dir = cfg().dir
  if st.main_folder and fn.isdirectory(dir .. '/' .. st.main_folder) == 0 then
    st.main_folder, st.current_folder = nil, nil
    return
  end
  if st.current_folder and fn.isdirectory(dir .. '/' .. st.current_folder) == 0 then
    st.current_folder = st.main_folder -- упавшая выбранная папка → назад на текущий уровень
  end
end
```

## 6. Рекурсивные конфликты (`folder_has_conflict`, `picker.lua`)

Сделать `folder_has_conflict(folder)` рекурсивным: `true`, если любая заметка из `state.conflicts`
имеет `folder == folder` **или** `n.folder:sub(1, #folder + 1) == folder .. '/'`. Используется
и в conflict-guard'ах (`rename_folder`/`delete_folder`), и в рекурсивной подсветке `render_folders`.
`is_conflicted(file)` — без изменений.

## 7. Создание / переименование / удаление подпапок (`picker.lua`)

### `create_folder()` — внутрь текущего уровня
- База = `cfg().dir .. (main_folder and ('/' .. main_folder) or '')`.
- `vim.ui.input` имя, **отклонять `/`** (одно leaf-имя за раз; вложенность набирается drill-down'ом).
  Сообщение убрать/поправить (сейчас `Nested folders are not supported` — теперь смысл иной:
  `Folder name cannot contain "/"`).
- `mkdir -p` + скрытый `.gitkeep`.
- Опционально: `current_folder = <new rel>` и курсор на новую строку (она всплывает наверх детей,
  т.к. mtime каталога = now), чтобы колонка Notes сразу показала пустую папку. `populate()` + `sync()`.

### `rename_folder()` — вложенные пути
- `f = selected_folder()`. Отклонять только истинный корень (`f.is_main and main_folder == nil`);
  переименование main-строки (сама папка) и детей разрешено.
- `default` = leaf-имя: `f.folder:match('[^/]+$')`. Отклонять `/` в вводе.
- Conflict-guard: `folder_has_conflict(f.folder)` (уже рекурсивный).
- `parent = f.folder:match('^(.*)/[^/]+$')`; `newrel = parent and (parent .. '/' .. input) or input`.
- `oldp = dir .. '/' .. f.folder`, `newp = dir .. '/' .. newrel`.
- Сохранить-перед-переносом открытую заметку, если она внутри (`cur:sub(1, #oldp + 1) == oldp .. '/'`)
  — существующая логика; `fn.rename(oldp, newp)`; переоткрыть редактор по `newp .. cur:sub(#oldp + 1)`.
- **Переписать префиксы** `current_folder` и `main_folder`, если они равны `f.folder` или начинаются
  с `f.folder .. '/'` → заменить префикс на `newrel` (хелпер `rewrite_prefix(path, old, new)`).
- `populate()` + `sync()`.

### `delete_folder()` — вложенные пути
- `f = selected_folder()`. Отклонять истинный корень. Conflict-guard рекурсивный. `confirm`.
- `path = dir .. '/' .. f.folder`. Если открытая заметка внутри (`== path` или `path .. '/'` префикс)
  → `ui.show_placeholder()`. `fn.delete(path, 'rf')`.
- Обновить навигацию:
  - если `main_folder == f.folder` или начинается с `f.folder .. '/'`:
    `main_folder = f.folder:match('^(.*)/[^/]+$')` (родитель/nil), `current_folder = main_folder`;
  - иначе если `current_folder == f.folder` или внутри неё: `current_folder = main_folder`.
- `populate()` + `sync()` (`validate_folder` — страховочный backstop по диску).

### `create_note()` / `delete_note()` / `paste_note()` (перенос заметки)
Логика не меняется — они уже используют `current_folder` как относительный путь; `dir/<rel>`
корректно работает для вложенных папок (`target_dir = f.folder and dir .. '/' .. f.folder or dir`).
Проверить только, что путь строится через `current_folder`/`f.folder` без предположения об одном уровне.

## 8. UI (`lua/notes/ui.lua`)

`editor_path_label(path)` **менять не нужно** — уже извлекает полный путь папки через
`rel:match('^(.+)/[^/]+$')` и работает для любой глубины (`folder/subfolder/title`). Проверить, что
statusline редактора корректно показывает вложенный путь.

## 9. Тесты (`test/picker_spec.lua`, при необходимости `test/sync_*`)

Обновить сломавшиеся существующие тесты под новую структуру `state.folders` (появилось поле
`is_main`; на корне дети = топ-уровневые папки, строка 1 = `Notes`). Добавить новые кейсы:
- Рекурсивный `scan`: `dir/A/B/note` → запись с `folder == 'A/B'`; `all_folders` содержит `A` и `A/B`.
- `build_folders` drill-down: на корне — `Notes` + топ-уровневые дети (без внуков); после установки
  `main_folder = 'A'` — main-строка + только непосредственные дети `A`.
- `change_folder`: вход в ребёнка ставит `main_folder`/`current_folder`; `o` на main-строке
  поднимает к родителю; из топ-уровня — в корень (nil).
- Рекурсивная свежесть: свежая заметка во внуке всплывает папку-предка наверх среди детей.
- `create_folder` внутрь текущего уровня: при `main_folder='A'` создаётся `dir/A/<name>`, `.gitkeep`.
- `rename_folder` вложенной: диск переименован, заметки переехали, префиксы
  `current_folder`/`main_folder` переписаны, редактор переоткрыт.
- `delete_folder`: удаление ребёнка → `current_folder` откатывается на `main_folder`; удаление
  main-папки → подъём к родителю.
- Рекурсивная подсветка конфликта: конфликт в `A/B/note` подсвечивает строку `A` при просмотре корня.
- `validate_folder` по диску: несуществующая `current_folder` → сброс на `main_folder`/nil.
- `paste_note` заметки во вложенную выбранную папку.
- (Опционально) в `test/sync_spec.sh` добавить сценарий с заметкой во вложенном пути
  (напр. конфликт в `A/B/note.txt`), чтобы покрыть nested-пути в merge-модели.

Прогон: `bash test/run.sh` должен выйти с кодом 0.

## 10. Документация

- **CLAUDE.md** — обновить: high-level «Folders are one level deep» → drill-down вложенность;
  таблицу/описание `M.state` (добавить `main_folder`); `config.keys` (добавить `change_folder`);
  описания `scan` (рекурсивный + `all_folders`), новый `build_folders`, `render_folders` (drill-down,
  рекурсивные конфликты), `filter`, `validate_folder` (проверка по диску), `create_folder`
  (внутрь текущего уровня), `rename_folder`/`delete_folder` (вложенные пути), новую `change_folder`,
  `attach_folders` (привязка `o`). Явно отметить, что **перенос целых папок пока не поддерживается**.
- **README.md** и **README.ru.md** (держать в синхроне) — список фич (вложенные папки), ASCII-схема
  окна Folders (drill-down), таблица клавиш (добавить `o` = change folder / go up), при
  необходимости раздел про навигацию по папкам.

## Критичные файлы

- `lua/notes/picker.lua` — основная часть (scan, build_folders, render_folders, change_folder,
  validate_folder, folder_has_conflict, create/rename/delete_folder, attach_folders).
- `lua/notes/init.lua` — `M.state.main_folder`, `M.config.keys.change_folder`, сброс в `is_open()`.
- `lua/notes/ui.lua` — сброс `main_folder` в `close()` (проверить `editor_path_label`).
- `test/picker_spec.lua` — новые и обновлённые кейсы; опц. `test/sync_spec.sh`.
- `CLAUDE.md`, `README.md`, `README.ru.md` — документация.

## Verification

1. `bash test/run.sh` → exit 0 (picker spec + git-sync spec).
2. Smoke/ручной прогон (dev-загрузка из CLAUDE.md, `require('notes').setup({ dir=... })`, `:Notes`):
   - создать вложенность `A` → войти `o` → создать `B` внутри → добавить заметки на разных уровнях;
   - проверить, что колонка Notes показывает прямые заметки выбранного уровня, `o` вверх/вниз работает,
     свежая заметка во внуке поднимает предка наверх;
   - переименовать/удалить вложенную папку при открытой внутри заметке — редактор корректно
     переоткрывается/сбрасывается в placeholder;
   - статуслайн редактора показывает `A/B/title`;
   - с настроенным `repo` — конфликт во вложенной заметке подсвечивает всю цепочку папок и
     разрешается сохранением (merge-синхронизация не сломана).
