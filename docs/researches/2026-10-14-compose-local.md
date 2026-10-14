# Ресерч 2026-10-14 — сервис Claude в отдельном файле вне git проекта

Вопрос беседы: где держать сервис `claude` в проекте, у которого свой compose-файл уезжает в деплой на прод, и видит ли Claude сервисы проекта, когда его сервис лежит в отдельном файле. Поводы — отчёт сессии `/box-init` пилотного проекта и замечание пользователя. Решения — `DECISIONS.md` 2026-10-14 «сервис Claude проекта: где держать и как назвать файл»; задача — `tasks/compose-local.md`.

## Пилотный проект

- `/box-init` вписывает сервис `claude` в `services:` compose-файла проекта (`skills/box-init/SKILL.md`, шаг 2). Профиль `claude` убирает сервис из `docker compose up`, а файл с ним — с подключением домашней папки, образом `maksim44/claude-box` и строкой адресов `CLAUDE_BOX_ALLOW` — идёт в git проекта и в его деплой на прод.
- Папка пилотного проекта — дополнительная рабочая копия git (worktree): на месте каталога `.git` лежит файл со строкой `gitdir: <основной репозиторий>/.git/worktrees/<имя>`. Путь есть только на хосте, в контейнере любая команда git кончается `fatal: not a git repository`, и `/box-init` останавливается на проверке чистого рабочего дерева (отчёт сессии `/box-init` пилотного проекта).
- Настройки, хуки, список исключений, объекты и ветки worktree лежат в `.git` основного репозитория, в `.git/worktrees/<имя>` — только своё рабочей копии: `HEAD`, индекс. Подключения образца только на чтение берут `./.git/config`, `./.git/hooks`, `./.git/info` внутри папки проекта, а у worktree `.git` — файл; ожидание — контейнер с образцовым compose-файлом в worktree не стартует, не проверено.

## Проба сети — Compose 5.6.0, образ `alpine`

Тестовая папка: `compose.yml` с сервисом `db` (`sleep 3600`) и `claude-box.yml` с одним сервисом `claude`, `profiles: [claude]`, командой `ping -c1 db`. Проект Compose — по имени папки у обоих файлов.

- Проект поднят `docker compose up -d`, затем `docker compose -f claude-box.yml run --rm claude`: Claude в сети `<папка>_default` проекта, `db` отвечает по имени.
- Порядок не важен: запуск Claude первым создаёт сеть `<папка>_default`, поднятый после него проект встаёт в неё же, база видна по имени.
- `docker compose down` проекта при работающем Claude: база остановлена и удалена, сеть остаётся — «Network … Resource is still in use», код выхода 0; Claude работает дальше, следующий `up` проекта встаёт в ту же сеть.
- `docker compose up -d --remove-orphans` проекта работающий контейнер Claude, запущенный `run`, не трогает.
- Каждый запуск Claude из `claude-box.yml` при поднятом проекте печатает в stderr `Found orphan containers (<контейнеры проекта>) for this project … --remove-orphans`. `--progress quiet` строку оставляет, переменная окружения `COMPOSE_IGNORE_ORPHANS=true` её убирает. Строка советует `--remove-orphans`; в команде запуска Claude этот флаг, по смыслу предупреждения, удалит контейнеры проекта — не проверено.
- Основной compose-файл со строкой `name: shop`: проект — в сети `shop_default`, Claude из `claude-box.yml` без этой строки — в сети по имени папки, `ping: bad address 'db'`. Та же строка `name: shop` в начале `claude-box.yml` возвращает общую сеть: база по имени отвечает.

## Выводы для задачи

- Отдельный файл только с сервисом `claude`, запуск `docker compose -f claude-box.yml …`: Claude в сети проекта, когда имя проекта Compose у двух файлов одно — по папке или по одинаковой строке `name:`. Имя проекта задаёт и путь папки проекта в контейнере, `/workspace/${COMPOSE_PROJECT_NAME}`, а к нему привязаны сессии Claude Code.
- Движок передаёт Compose `COMPOSE_IGNORE_ORPHANS=true`; при ручном запуске предупреждение остаётся.
- Контейнер агента задаёт один `claude-box.yml` с явным `-f`: основной compose-файл проекта на контейнер следующего запуска уже не влияет.
- Абсолютный путь к основному репозиторию worktree — путь этой машины: подключение `.git` основного репозитория ложится в тот же файл под `.gitignore`.

## Проба образца и движка — шаг «Отдельный файл», Compose 5.6.0, образ `maksim44/claude-box` от 2026-10-14

Временная папка: копия `template/` с `claude-box.yml` образца, git-репозиторий, основной `compose.yml` с сервисом `db` (`alpine`, `sleep 3600`) и строкой `name: shopprobe`, та же строка в `claude-box.yml` над `services:`.

- `/claude-box.yml` в `.gitignore` образца: `git check-ignore` называет эту строку, `git status --porcelain` после коммита пуст.
- `docker compose -f claude-box.yml --profile claude config --services` печатает `claude`.
- Проект поднят `docker compose up -d`; `docker compose -f claude-box.yml run --rm --entrypoint getent claude hosts db` печатает адрес базы (`172.31.0.2 db`) и перед ним строку `Found orphan containers (shopprobe-db-1) … --remove-orphans`. С `COMPOSE_IGNORE_ORPHANS=true` строки в stderr нет.
- `docker compose -f claude-box.yml run --rm --remove-orphans --entrypoint true claude` удаляет контейнер базы проекта: `Container shopprobe-db-1 Removed`, контейнеров проекта после запуска нет.
- `agent-loop.sh --quiet t` из папки при поднятой базе, задача из одного шага — файл со строкой: итерация в контейнере из `claude-box.yml` за ограничением сети закончилась за 38 с, 6 ходов, двумя коммитами — шаг и журнал, статус «готово», код выхода движка 0.
