# Ресерч 2026-09-24 — Claude Code в контейнере

Вопрос сессии: как поднять Claude Code в Docker-контейнере и работать в нём, запуская одной командой в любом проекте и совместимо со step-harness. Здесь — схема, факты, проверки и источники. Аутентификация и bypass в контейнере — `2026-08-31-audit-and-headless.md` § Контейнер.

## Схема

- Образ хранит только запуск: при старте контейнер ищет `claude`, при отсутствии ставит его официальным установщиком, затем запускает. Установка ложится в `~/.local` пользователя `node` — в домашнюю папку контейнера: скачивается один раз на машину и дальше обновляется сама в фоне.
- Образ публичный, на Docker Hub под аккаунтом пользователя — `maksim44/claude-box`. Личного в нём нет: логин живёт в домашней папке контейнера, личное с хоста приезжает при запуске.
- Домашняя папка хоста подключается только на чтение в `/root/host-home`: `/root` закрыт для `node`. Скрипт запуска стартует от root, копирует оттуда то, что есть, — `~/.claude/CLAUDE.md`, `~/.claude/hooks/`, `~/.gitconfig`, скрипт строки состояния из `statusLine` хостового `settings.json` с путём, переведённым в контейнер, — и запускает Claude Code от `node` через `setpriv`. Чего нет на хосте, того нет в контейнере; копия прошлого запуска убирается. Настройки контейнера собираются при каждом старте: язык, модель, effort, приписка коммитов и строка состояния — из хостового `settings.json`, регистрация хука context-guard — из образа, при наличии скрипта хука.
- Запуск — сервис `claude` в `compose.yml` проекта: `docker compose run --rm claude`, одна команда на Linux, macOS и Windows в любом shell. Флаги после имени сервиса уходят в Claude Code.
- Домашняя папка контейнера `/home/node` — папка хоста `~/.claude-box`: логин, история сессий и сам Claude Code общие для всех проектов машины. Проект подключается в `/workspace/${COMPOSE_PROJECT_NAME}` — сессии, автопамять и доверие каждого проекта лежат в ней отдельно.
- Проектное (хаб, `docs/PROTOCOL.md`, таск-файлы, `/next`, `.claude/context-guard.conf`) приезжает с папкой проекта — `/next` внутри работает как на хосте. Итерация движка — тот же сервис: `docker compose run --rm -e CONTEXT_GUARD_MODE=protocol claude -p "/next <задача>" …`, движок на хосте, код выхода возвращается ему.

Итог — в step-harness: образ `container/` (Dockerfile, скрипт запуска `entrypoint.sh`, регистрация хука `settings.json`), сервис — `template/compose.yml`; запуск и обновление образа — `README.md` step-harness § Запуск и § Деплой.

- `profiles: [claude]` — обычный `docker compose up` проекта контейнер Claude не поднимает.
- Бонус compose проекта: Claude в одной сети с сервисами проекта, база доступна по имени сервиса.

## Почему так

- Референс Anthropic `.devcontainer` (Dockerfile, firewall, настройки VS Code) — пример, не поддерживаемый образ; под терминал и один запуск избыточен. Его firewall нужен прогонам с `--dangerously-skip-permissions` — вопрос движка, открыт.
- Установка Claude Code при сборке образа фиксирует версию: npm-каталог принадлежит root, контейнер работает от `node`, обновление не записывается; `--rm` стирает контейнер вместе с любыми правками. Обновление в такой схеме — пересборка с `--no-cache` и `push`. Пользователь выбрал установку при старте.
- Shell-функция или алиас — свой вариант под каждый shell и ОС; сервис compose — одна команда везде.
- Подключения (папка проекта, домашние папки) в Dockerfile не записываются: Docker задаёт их только при запуске.
- Опциональность — в скрипте запуска: у Compose нет подключения «если есть», отсутствующий источник short syntax создаёт каталогом от root. Подключается домашняя папка хоста — она есть всегда, — а выбор делает скрипт. Спрятана она путём: подключённое изнутри контейнера не отключить без расширенных прав, но в закрытый `/root` пользователь `node` не войдёт — ни напрямую, ни через `/proc/<pid>/root`.
- Домашняя папка контейнера — папка хоста, а не именованный volume: общий volume Compose приписывает создавшему его проекту и в каждом другом проекте на каждом запуске предупреждает «volume already exists but was created for project …». Папку при первом запуске Compose создаёт от root, скрипт запуска отдаёт её `node`; в `compose.yml` проекта нет блока `volumes:`.
- Настройки берутся с хоста при каждом старте — выбор пользователя вместо значений, вписанных в step-harness: правка хостового `settings.json` доезжает до контейнера сама. Целиком хостовый файл настройками контейнера служить не может — § Хостовый `~/.claude` и контейнер.
- Строка состояния в контейнере — не только вид; скрипт берётся из хостовых настроек, имя у него может быть любым: она оставляет снимок с размером окна для хука context-guard; без неё интерактивная сессия в контейнере шла бы по ветке headless — занятость по переписке, свой порог.
- Проект подключается под своим именем: Claude Code раскладывает сессии, автопамять (`~/.claude/projects/<путь>/memory`) и доверие по пути рабочего каталога; с общим `/workspace` все проекты в общей домашней папке делили бы их. `${COMPOSE_PROJECT_NAME}` Compose подставляет сам, из подпапки проекта — то же имя; `${PWD}` из подпапки даёт путь подпапки.
- Каталог настроек — по умолчанию, `~/.claude`: подключение покрывает всю `/home/node`. `CLAUDE_CONFIG_DIR` референса нужен там, где volume только на `~/.claude`.

## Документация Claude Code

- Официальный способ поставить Claude Code в контейнер — Dev Container Feature `ghcr.io/anthropics/devcontainer-features/claude-code`: ставит последнюю версию, внутри контейнера Claude Code по умолчанию обновляется сам. Фиксация версии — `npm install -g @anthropic-ai/claude-code@X.Y.Z` в Dockerfile и `DISABLE_AUTOUPDATER=1`.
- `.devcontainer` репо `anthropics/claude-code` — «working example rather than a maintained base image».
- Нативный установщик — `curl -fsSL https://claude.ai/install.sh | bash`; лаунчер `~/.local/bin/claude` — симлинк в `~/.local/share/claude/versions/`; нативная установка обновляется в фоне.
- npm-установка без прав записи в глобальный каталог npm не обновляется, при старте — разовое уведомление, варианты — `claude doctor`.
- `DISABLE_AUTOUPDATER=1` выключает фоновую проверку обновлений; `DISABLE_UPDATES` — все пути обновления, включая `claude update`.
- Docker Sandboxes — отдельный продукт Docker, microVM со своим Docker-демоном; в доке — вариант VM-изоляции. Не изучался.

## Референс `.devcontainer` — снимок 2026-09-24

`node:20`, пользователь `node`; apt ставит `git`, `jq`, `iptables`, `ipset` и др.; Claude Code — `npm install -g` от `node` в `NPM_CONFIG_PREFIX=/usr/local/share/npm-global`; volume на `/home/node/.claude` и `CLAUDE_CONFIG_DIR`; firewall — `init-firewall.sh` через `sudo` в `postStartCommand`, `--cap-add=NET_ADMIN --cap-add=NET_RAW`. Allowlist: диапазоны GitHub из `api.github.com/meta`, `registry.npmjs.org`, `api.anthropic.com`, `sentry.io`, `statsig.com`, домены VS Code. PyPI в allowlist нет — `pip install` за этим firewall упирается в сеть.

## Docker Hub

- Официального образа Claude Code нет.
- `anthropics/claude-code`: один тег `latest` от 2026-06-18, только amd64, без описания, 5760 скачиваний; в доке Claude Code не упоминается — происхождение не подтверждено.
- Прочие `*/claude-code` — сторонние сборки (kasmweb, chatwork и др.); внутрь попадал бы логин пользователя.
- `docker/sandbox-templates` несёт теги `claude-code*` — образы Docker Sandboxes.

## Docker и Compose

- Папка хоста из Dockerfile не подключается; `VOLUME` в Dockerfile при запуске без подключения создаёт безымянный volume, каждый раз новый.
- Новый именованный volume при первом подключении заполняется содержимым образа по этому пути вместе с владельцами; последующие изменения образа в него не доезжают.
- `--rm` удаляет контейнер, именованный volume остаётся.
- Неизменённый `RUN` берётся из кэша слоёв: обновить установленное при сборке — `docker build --no-cache`.
- Compose уже скачанный образ заново не тянет — `docker compose pull <сервис>`.
- Compose приклеивает имя проекта к имени volume; `name:` фиксирует имя.
- Прямой `docker compose run` сервиса с профилем активирует профиль — по доке Compose.
- `docker build` собирает под архитектуру своей машины; amd64 + arm64 разом — `docker buildx build --platform linux/amd64,linux/arm64 … --push`.

## Проверено локально

- `docker compose config`: `build.dockerfile_inline` принимается; `~` в источнике bind раскрывается в домашнюю папку; `.` — папка compose-файла; с `-f <путь> --project-directory .` подключается текущая папка; volume с `name:` — без префикса проекта.
- Сервис с `profiles: [claude]`: в `config --services` без профиля отсутствует, с `--profile claude` — есть.
- `node:20`: есть `curl`, `git` 2.39.5; `jq` нет; пользователь `node` — uid 1000: файлы из контейнера на хосте принадлежат пользователю хоста с тем же uid; `/home/node` принадлежит `node`.
- `ENTRYPOINT ["sh", "-c", "… \"$@\"", "claude"]` передаёт аргументы запуска в команду без потерь.
- Отсутствующий на хосте источник bind Compose создаёт пустым каталогом от root — и для пути, где ожидался файл.

## Проверено в контейнере — Claude Code 2.1.281

- Сборка образа; первый старт ставит Claude Code за ~35 с, второй стартует за 0,3 с.
- Вход изнутри — ссылка в браузер хоста, код обратно в терминал; креды лежат в домашней папке контейнера и работают в новом контейнере после `--rm`.
- Настройки собираются из хостового `settings.json`: язык, модель, effort, приписка; строка состояния показывается и пишет снимок для хука; `/next` виден в интерактиве.
- Хук context-guard: подстановкой по описанию хука — сигнал во всех трёх ветках (снимок; headless + `protocol` из окружения; headless + `rules` из файла проекта). Вживую в `-p` с заниженным порогом — сигнал режима `rules` после второго вызова инструмента; после первого хук молчит: ответ модели с этим вызовом в момент `PostToolUse` ещё не записан в переписку — отставание на шаг из описания хука.
- Коммит изнутри — автор из `~/.gitconfig`; созданные файлы на хосте принадлежат пользователю.
- `docker compose run` без `-T` из-под процесса без терминала работает; код выхода Claude Code возвращается вызывающему.
- `${COMPOSE_PROJECT_NAME}` — имя папки compose-файла, из подпапки то же; сессии проекта ложатся в `~/.claude/projects/-workspace-<имя>`.
- Домашняя папка хоста в `/root/host-home`: root её читает, `node` получает «Permission denied» — напрямую, через `/proc/1/root` и `/proc/self/root`; `claude -p` работает от `node`.
- Опциональность: при домашней папке хоста без `CLAUDE.md`, хуков и `.gitconfig` старт проходит, копий прошлого запуска нет, регистрации хука в настройках нет; при пустой домашней папке настройки контейнера — `{}`.
- Строка состояния со скриптом в подпапке `~/.claude` и полем `padding`: файл скопирован в подпапку, путь в команде переведён, `padding` сохранён.
- Первый запуск без `~/.claude-box`: Compose создаёт папку от root, скрипт запуска отдаёт её `node`, на хосте она принадлежит пользователю; Claude Code ставится. Второй проект с той же папкой — без предупреждений Compose.
- Модель в контейнере следует хостовому `settings.json` на момент старта.

## Хостовый `~/.claude` и контейнер

- Агенту достаются только копии: `CLAUDE.md`, `hooks/`, скрипт строки состояния, `.gitconfig`, ключи из `settings.json`. Креды (`.credentials.json`), переписка хоста и остальная домашняя папка лежат в закрытом `/root`, логин в контейнере свой: в bypass агент читает всё, что видит его пользователь.
- Хостовый `settings.json` целиком настройками контейнера служить не может: хуки и строка состояния прописаны абсолютными путями домашней папки хоста. Поэтому из него берутся только `language`, `model`, `effortLevel`, `modelSettings`, `attribution`, `includeCoAuthoredBy` и `statusLine` с переведённым путём.
- Хук context-guard без `jq` выходит молча (`command -v jq || exit 0`): сигнала нет, длинная сессия уходит во встроенное автосжатие вместо протокола.
- Язык ответа, модель, effort задаются в хостовом `settings.json` (`language`, `model`, `effortLevel`); в `CLAUDE.md` их нет.
- Остаются на хосте: скиллы `~/.claude/skills`, плагины, MCP из `~/.claude.json`, `keybindings.json`, ключи `~/.ssh` — push с хоста.
- Коммит протокола требует имя и почту автора git — `~/.gitconfig` копируется в контейнер.

## Не проверено

- смена настройки изнутри (`/model`): `settings.json` контейнера доступен на запись, следующий старт перезаписывает его значениями хоста;
- `docker buildx` под две архитектуры; запуск на macOS и Windows.

## Источники

- https://code.claude.com/docs/en/devcontainer
- https://code.claude.com/docs/en/setup
- https://code.claude.com/docs/en/sandbox-environments
- https://github.com/anthropics/claude-code/tree/main/.devcontainer
- https://hub.docker.com/r/anthropics/claude-code
- https://docs.docker.com/reference/dockerfile/#volume
- https://docs.docker.com/engine/storage/volumes/
- https://docs.docker.com/compose/how-tos/profiles/
- https://docs.docker.com/reference/compose-file/services/#volumes — `create_host_path`
- https://docs.docker.com/reference/compose-file/version-and-name/ — `COMPOSE_PROJECT_NAME` в подстановке
