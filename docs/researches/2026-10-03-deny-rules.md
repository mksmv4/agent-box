# Ресерч 2026-10-03 — deny-правила и защита compose-файла

Вопрос сессии: чем закрыть неприкасаемое проекта от агента контейнерной ступени, в том числе в bypass, и как закрыть правку агентом `compose.yml` своего проекта. Шаг задачи `agent-loop` «Deny-правила образца и защита `compose.yml`»; состав неприкасаемого — блокер шага.

## Документация Claude Code — снимок 2026-10-03

- Deny-правила блокируют в любом режиме, включая `bypassPermissions`; allow-правила в bypass значения не имеют.
- `Read`- и `Edit`-правила действуют на встроенные файловые инструменты, на файловые команды Bash, которые Claude Code распознаёт (`cat`, `head`, `tail`, `sed`, `tee`), и на цели перенаправлений `> file`, `< file`. Команда, читающая файлы без имени (`grep -r pattern .`), и любой подпроцесс, открывающий файлы сам (скрипт Python или Node), мимо них. Принудительный запрет на уровне ОС — песочница Claude Code.
- `Read`-deny закрывает на том же пути и `Edit`/`Write`, включая создание файла; `NotebookEdit` — только `Edit`-deny.
- Пути в правилах — синтаксис gitignore: `//path` — от корня файловой системы, `~/path` — от домашней папки, `/path` — от источника настроек (у `.claude/settings.json` — основной рабочий каталог), `path` и `./path` — от текущего каталога. Голое имя файла совпадает на любой глубине: `Read(.env)` равно `Read(**/.env)`.
- Bash-правило сверяет текст команды после разбивки составной команды и снятия обёрток: `Bash(git push *)` не ловит `git -C . push`, `git -c … push`, `sh -c '…'`, вызов по полному пути. Дока прямо называет такие правила не границей безопасности.
- Защищённые пути — `.git`, `.claude`, `.config/git`, `.husky`, `.devcontainer` и др., файлы `.gitconfig`, `.mcp.json`, `.claude.json` и др.: запись в них Manual и acceptEdits спрашивают, auto отдаёт классификатору, dontAsk отклоняет, `bypassPermissions` пропускает. Allow-правила запись в защищённые пути не разрешают.
- Managed settings пользователь и проект переопределить не могут.

## Пробы 2026-10-03 — Compose 5.6.0, git на хосте, образ `maksim44/claude-box`

- `compose.override.yml` рядом с `compose.yml` Compose подмешивает сам: подключение `/:/host` из него попало в итог `docker compose config`.
- Строка `COMPOSE_FILE=evil.yml` в `.env` папки проекта подменяет compose-файл целиком; явный `-f compose.yml` её перекрывает.
- `git status` на хосте выполняет команду из `core.fsmonitor` в `.git/config` и хук `post-index-change` из `.git/hooks`; `git diff --name-only` и `git rev-parse` хуков не запускают. Файл `.git/commondir` переадресует чтение настроек git в другую папку — команда из её `config` выполнилась так же.
- `git -c core.fsmonitor=false -c core.hooksPath=/dev/null status` — ни команды, ни хука, в том числе при переадресации через `commondir`.
- Файл, подключённый поверх папки проекта только на чтение (`-v …/compose.yml:/w/compose.yml:ro`), пользователь uid 1000 в контейнере не меняет ничем: запись shell и Python — «Read-only file system», `mv` и `rm` — «Device or resource busy». Так же закрыты `.git/config` (`git config` — ошибка записи) и `.git/hooks`; коммит при этом проходит. Новый файл рядом — `compose.override.yml` — создаётся.

## Выводы для шага

- Deny-правила — защита от обычных действий агента: инструментами и распознанными командами. Скрипт агента их обходит, а в bypass агент может и стереть их из `.claude/settings.json` проекта: защищённые пути bypass пропускает.
- Значения `.env` агент контейнера видит и без файла: `env_file` сервиса кладёт их в окружение контейнера (`ARCHITECTURE.md` § Образец проекта). Запрет на чтение `.env` закрывает сам файл.
- Агент контейнера меняет контейнер следующего запуска тремя путями: правкой compose-файла, файлом `compose.override.yml` рядом и строкой `COMPOSE_FILE` в `.env`.
- Агент контейнера выполняет команды на хосте через `.git` проекта: настройки и хуки git срабатывают на `git status`, а его движок делает после каждой итерации. В git-истории и диффе таких правок не видно.
- Жёсткий запрет внутри контейнера — подключение файла только на чтение; отсутствующий файл так не закрыть: Compose создаст на его месте каталог.

## Источники

- https://code.claude.com/docs/en/permissions — § Read and Edit, § What a Bash rule doesn't match, § Managed settings
- https://code.claude.com/docs/en/permission-modes — § Protected paths, § Skip all checks with bypassPermissions mode
- https://git-scm.com/docs/git-config — `core.fsmonitor`, `core.hooksPath`
- https://git-scm.com/docs/gitrepository-layout — `commondir`
- https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/ — `compose.override.yml`
- https://docs.docker.com/compose/how-tos/environment-variables/envvars/ — `COMPOSE_FILE`
