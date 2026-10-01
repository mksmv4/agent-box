# agent-box

Чтение на старте: @docs/RULES.md @docs/README.md @docs/PROTOCOL.md

## Суть проекта

agent-box — обвязка проектов под работу с Claude Code (`docs/DESCRIPTION.md`). Продукт — три папки: образец проекта `template/`, скиллы контейнера `skills/` и образ `container/`; их файлы правятся как код. Хаб, документы и протокол в `template/` — правила проектов, куда ляжет образец; в этом проекте они не действуют: настройка `claudeMdExcludes` в `.claude/settings.json` выключает их для сессий этого репозитория. Сам репозиторий ведётся по обвязке своим каркасом в корне — `AGENTS.md`, `docs/`, `.claude/`.

## Жёсткие ограничения

- Правка рабочего оригинала — `template/docs/PROTOCOL.md` или `template/.claude/skills/box-next/` — тем же коммитом копируется в `docs/PROTOCOL.md` и `.claude/skills/box-next/`: сессии этого репозитория работают по копиям.
- `/box-init` на этом репозитории разберёт `template/` и `skills/` как старую документацию и унесёт их в архив; каркас этого репозитория правится руками.

## Грабли

- Контейнер, открытый до пересборки образа, работает со старыми скиллами: копию скиллов образа скрипт запуска кладёт в `~/.claude/skills` только при старте. Правка `skills/` проверяется в новом контейнере после пересборки (`docs/ARCHITECTURE.md` § Правила зависимостей); повторный `/box-init` в старом контейнере сверил очередь сборки со старым шаблоном и нашёл «совпадение».

## Точки входа

- `README.md` — для человека: quick start, запуск, пересборка образа
- `template/` — образец проекта, который `/box-init` кладёт в проект
- `template/docs/PROTOCOL.md` — рабочий оригинал протокола
- `template/.claude/skills/box-next/SKILL.md` — рабочий оригинал `/box-next`
- `skills/box-init/SKILL.md` — `/box-init`: заведение проекта и шаблон задачи сборки документации
- `skills/box-init/documents.md` — карточки документов проекта
- `skills/box-task/SKILL.md` — `/box-task`: заведение задачи
- `container/Dockerfile` — образ `claude-box`
- `container/entrypoint.sh` — скрипт запуска контейнера
- `container/settings.json` — базовые настройки образа с регистрацией хука context-guard
- `compose.yml` — сервис `claude` этого репозитория
- `.claude/settings.json` — настройки Claude Code этого репозитория: `claudeMdExcludes` для `template/`
