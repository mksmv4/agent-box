статус: блокер

# compose-local

## Постановка

Цель: сервис Claude в проекте живёт в отдельном файле `claude-box.yml` в корне проекта под `.gitignore`: основной compose-файл проекта, его git и деплой сервиса Claude не несут. Claude из этого файла — в одной сети с сервисами проекта, база доступна по имени сервиса, в том числе когда основной compose-файл задаёт имя проекта строкой `name:`. Ручной запуск — `docker compose -f claude-box.yml run --rm claude`, движок ведёт итерации из того же файла. Уже заведённый проект переходит на отдельный файл повторным `/box-init`.

Вторая часть цели — проект в дополнительной рабочей копии git (worktree): в контейнере работают git и коммит, а настройки, хуки и список исключений git основного репозитория изнутри контейнера закрыты на запись, как в основной копии.

Очередь:

- [x] Проба сети: тестовая папка с основным compose-файлом с сервисом базы и `claude-box.yml` с сервисом `claude` — Claude из отдельного файла видит базу по имени при любом порядке запуска, переживает `down` проекта, строка `name:` основного файла нужна и в `claude-box.yml`; итог — `researches/2026-10-14-compose-local.md`.
- [x] Отдельный файл: образец `template/compose.yml` → `template/claude-box.yml`, первая строка — назначение и команда запуска; `/box-init` (`skills/box-init/SKILL.md`, шаги 2–4 и 8) кладёт `claude-box.yml` в любой проект — со своим compose-файлом и без, — дописывает его в `.gitignore`, переносит строку `name:` основного compose-файла; в уже заведённом проекте сервис `claude` основного compose-файла переезжает в `claude-box.yml` — запись в основной файл в контейнере закрыта, строки к удалению оттуда — в итог пользователю; движок `agent-loop.sh` берёт `claude-box.yml` вместо поиска compose-файла по именам Compose и передаёт Compose `COMPOSE_IGNORE_ORPHANS=true`; правило запрета `template/.claude/settings.json` и подключение только на чтение — на `claude-box.yml`; тексты `container/firewall.sh`, `README.md`, `docs/ARCHITECTURE.md`, `docs/DESCRIPTION.md` — под новую схему, в `README.md` — предупреждение: флаг `--remove-orphans`, который советует строка Compose о чужих контейнерах, в команде запуска Claude не ставится. Проверка: в тестовой папке во временной папке — git-репозиторий, основной compose-файл с сервисом базы и строкой `name:`, `claude-box.yml` из образца с той же строкой и под `.gitignore`: `docker compose -f claude-box.yml --profile claude config --services` печатает `claude`, `git status --porcelain` пуст, `docker compose -f claude-box.yml run --rm --entrypoint getent claude hosts db` печатает адрес базы; `agent-loop.sh` на задаче из одного шага в этой папке проходит итерацию из `claude-box.yml` без строки о чужих контейнерах. Файлы шага — около 126 тыс. символов.
- [x] Worktree: проба в тестовом репозитории с дополнительной рабочей копией — `.git` основного репозитория подключён в контейнер по тому же абсолютному пути, поверх только на чтение его `config`, `hooks` и `info`; первый запуск контейнера в worktree до `/box-init` — откуда контейнер берёт эти подключения; затем `/box-init` пишет их в `claude-box.yml` сам, когда `.git` проекта — файл, путь — из строки `gitdir:` этого файла. Проверка: в контейнере из worktree `git status` и коммит проходят, запись, `mv` и `rm` в `config`, `hooks` и `info` основного репозитория отклоняются; на хосте `git log` основной копии видит коммит ветки worktree. Файлы шага — ресерч, `skills/box-init/SKILL.md`, `template/claude-box.yml`, `docs/ARCHITECTURE.md`, `README.md`.
- [ ] Живая проверка — ведёт пользователь: сессия пишет блокером команды — пересборка образа (`README.md`); тестовый репозиторий с compose-файлом с сервисом базы и строкой `name:` и дополнительная рабочая копия от него; второй тестовый проект по старой схеме — сервис `claude` в основном compose-файле; в каждом — новый контейнер и `/box-init`, затем Claude в контейнере просит адрес базы по имени сервиса, затем `agent-loop.sh` на задаче из одного шага; затем команды уборки. Ожидание: `claude-box.yml` под `.gitignore` с той же строкой `name:`, основной compose-файл без сервиса `claude` — у проекта по старой схеме итог `/box-init` называет строки к удалению; Claude получает адрес базы; итерация движка закрывает задачу коммитом; в worktree `/box-init` проходит проверки git и делает коммит, запись в `.git/config` основного репозитория из контейнера отклоняется.

Проверка шага: правка образца и движка — проба во временной папке, ожидание записано в шаге; правка скилла и образа — живая проверка пользователем (`RULES.md` § Конвенции работы), последний шаг очереди.

Блокер: защита основного compose-файла проекта — правило запрета и подключение только на чтение: снимать ли её, когда контейнер агента задаёт `claude-box.yml`; перенос сервиса из основного compose-файла в заведённых проектах, когда путь шага не сработал; подключение основного репозитория worktree, не прошедшее пробу; первый запуск контейнера в worktree до `/box-init`, когда у него больше одного пути.

## Контекст

Следующий шаг — «Живая проверка»: блокер с командами отдан пользователю. По ответу — сверка с ожиданием из секции «Блокер»: всё сходится — чекбокс шага, статус «готово», запись журнала; расхождение — правка по нему в `skills/box-init/SKILL.md`, `template/claude-box.yml` или `agent-loop.sh` и новый круг живой проверки с теми же командами.

Образ `maksim44/claude-box` на хосте собран 2026-10-14 10:21 — до правок шагов «Отдельный файл» и «Worktree»: пересборка — первая команда блокера. Проект по старой схеме в блокере собирается из образца коммита `f806f12` — последнего до этой задачи: `compose.yml` с сервисом `claude` и подключением себя только на чтение, `.claude/settings.json` с правилами запрета compose-файлов; таск-файла `docs-*` в нём нет, и `/box-init` идёт первым заходом. Команды блокера проверены без записи файлов: `compose.yml` старой схемы с дописанным сервисом `db` проходит `docker compose config` с сервисами `claude db`, после `sed` блокера — только `db`.

Хвосты:

- `compose.yml` этого репозитория остаётся: в нём сборка образа (`docker compose build claude`), движок по задачам agent-box — с `--host` (`AGENTS.md` § Грабли); `README.md` § Запуск называет его.
- Правило песочницы для сессии хоста переустанавливать не нужно: его текст — «compose-файл в корне проекта», `claude-box.yml` под него подходит; текст в `agent-loop.sh` не менялся.
- Предложение: сервисы проекта только в своих сетях (`networks:` без сети по умолчанию) Claude из `claude-box.yml` по имени не увидит — не проверено; кандидат в отдельный шаг.
- Предложение: файл `.git` рабочей копии и её `commondir` в основном репозитории — только на чтение; оба открыты агенту на запись и переадресуют git к другим настройкам, тот же класс, что `.git/commondir` основной копии (`ARCHITECTURE.md` § Ступени изоляции, «Открыто»).
- Живая проверка: у обычного проекта и его рабочей копии одна строка `name: boxlive` и один путь в контейнере `/workspace/boxlive` — общие сессии и автопамять Claude Code (`README.md` § Запуск); первые запуски до `/box-init` — под путями от имён папок.
- Пилотный проект ждёт этой задачи: он сам — рабочая копия git; повторный `/box-init` в нём после пересборки образа, из контейнера первого запуска рабочей копии, перенесёт сервис в `claude-box.yml` с подключениями основного репозитория и снимет запрет на правку основного compose-файла.

Среда: тестовые проекты живой проверки — `/tmp/boxlive`, их создаёт пользователь командами блокера; временные папки прошлых проб `/tmp/compose-local-1usP`, `/tmp/wt-probe-shog`, `/tmp/wt-probe-scripts` и истории сессий тестовых проектов убирают команды уборки блокера.

## Блокер

Последний шаг задачи — живая проверка, её проходишь ты по командам ниже. Проверяется новая схема целиком, в новом контейнере: заведение проекта кладёт сервис Claude в отдельный файл вне git, Claude видит базу проекта по имени, автоцикл закрывает задачу. Проектов три, все тестовые, в папке `/tmp/boxlive`: обычный — с базой и строкой `name:` в compose-файле; его дополнительная рабочая копия git (worktree); проект по старой схеме — сервис Claude в основном compose-файле, как у проектов, заведённых раньше.

На вопросы `/box-init` по ходу: список адресов интернета — «ок», хранение архива — любой вариант. Выход из сессии Claude — `/exit`.

1. Подготовка — в терминале хоста в корне клона agent-box: пересборка образа (нынешний собран до правок этой задачи), три проекта — проект по старой схеме собирается из образца до этой задачи — и тестовая задача из одного шага.

```bash
docker compose build claude
d=/tmp/boxlive
mkdir -p $d/boxlive-main $d/boxlive-old/.claude
printf 'name: boxlive\nservices:\n  db:\n    image: alpine\n    command: sleep infinity\n' >$d/boxlive-main/compose.yml
git -C $d/boxlive-main init -q && git -C $d/boxlive-main add -A && git -C $d/boxlive-main commit -qm 'test project'
git -C $d/boxlive-main worktree add -q $d/boxlive-feat -b feat
git show f806f12:template/compose.yml >$d/boxlive-old/compose.yml
printf '  db:\n    image: alpine\n    command: sleep infinity\n' >>$d/boxlive-old/compose.yml
git show f806f12:template/.claude/settings.json >$d/boxlive-old/.claude/settings.json
git -C $d/boxlive-old init -q && git -C $d/boxlive-old add -A && git -C $d/boxlive-old commit -qm 'old scheme project'
printf 'статус: в работе\n\n# t\n\n## Постановка\n\n- [ ] файл hello.txt в корне проекта со строкой hello; проверка — cat hello.txt печатает hello\n\n## Контекст\n\nСледующий шаг — hello.txt.\n' >$d/t.md
```

2. Обычный проект. Первый запуск — команда из `README.md` § Запуск, в сессии — `/box-init`:

```bash
cd /tmp/boxlive/boxlive-main
n=$(basename "$PWD" | tr A-Z a-z | tr -cd 'a-z0-9_-' | sed 's/^[-_]*//')
docker run --rm -it -v "$PWD":/workspace/"$n" -w /workspace/"$n" -v "$HOME"/.claude-box:/home/node -v "$HOME":/root/host-home:ro maksim44/claude-box
```

Затем база проекта и Claude из нового файла, в сессии — вопрос «какой адрес у сервиса db?»; после выхода — проверка файла и автоцикл на тестовой задаче:

```bash
docker compose up -d
docker compose -f claude-box.yml run --rm claude
git check-ignore claude-box.yml; grep '^name:' claude-box.yml
cp ../t.md docs/tasks/ && git add docs/tasks/t.md && git commit -qm 'test task' && agent-loop.sh --quiet t
cat hello.txt; git log --oneline -4
```

3. Рабочая копия. Первый запуск — команда для рабочей копии из `README.md` § Запуск, в сессии — `/box-init`:

```bash
cd /tmp/boxlive/boxlive-feat
n=$(basename "$PWD" | tr A-Z a-z | tr -cd 'a-z0-9_-' | sed 's/^[-_]*//')
g=$(git rev-parse --path-format=absolute --git-common-dir)
docker run --rm -it -v "$PWD":/workspace/"$n" -w /workspace/"$n" -v "$g":"$g" -v "$g"/config:"$g"/config:ro -v "$g"/hooks:"$g"/hooks:ro -v "$g"/info:"$g"/info:ro -v "$HOME"/.claude-box:/home/node -v "$HOME":/root/host-home:ro maksim44/claude-box
```

Затем Claude из нового файла с тем же вопросом об адресе `db` — база уже поднята обычным проектом, имя проекта у них общее; после выхода — проверка файла, попытка записи в настройки git основного репозитория из контейнера и автоцикл:

```bash
docker compose -f claude-box.yml run --rm claude
git check-ignore claude-box.yml; grep -nE '^name:|\.git' claude-box.yml
docker compose -f claude-box.yml run --rm --entrypoint touch claude "$g"/config
cp ../t.md docs/tasks/ && git add docs/tasks/t.md && git commit -qm 'test task' && agent-loop.sh --quiet t
cat hello.txt; git log --oneline -4
```

4. Проект по старой схеме. Контейнер — по-старому, из основного compose-файла, в сессии — `/box-init`:

```bash
cd /tmp/boxlive/boxlive-old
docker compose run --rm claude
```

Итог `/box-init` называет строки сервиса Claude в `compose.yml` к удалению; первая команда ниже убирает весь сервис `claude` — сверь, что итог назвал эти строки. Затем база, Claude из нового файла с тем же вопросом об адресе `db`, проверка файлов и автоцикл:

```bash
sed -i '/^  claude:/,/^  db:/{/^  db:/!d}' compose.yml && git commit -qam 'claude service removed' && cat compose.yml
docker compose up -d
docker compose -f claude-box.yml run --rm claude
git check-ignore claude-box.yml; grep -nE 'compose|claude-box' .claude/settings.json
cp ../t.md docs/tasks/ && git add docs/tasks/t.md && git commit -qm 'test task' && agent-loop.sh --quiet t
cat hello.txt; git log --oneline -4
```

Ожидание:

- в каждом проекте `/box-init` кончается коммитом, `git check-ignore` печатает `claude-box.yml`; строка `name: boxlive` — в `claude-box.yml` обычного проекта и рабочей копии, у проекта по старой схеме строки `name:` нет;
- у рабочей копии в `claude-box.yml` — подключение `/tmp/boxlive/boxlive-main/.git` и поверх него его `config`, `hooks`, `info` с `:ro`, подключений `./.git/…` нет; `touch` отвечает `Read-only file system`;
- у проекта по старой схеме итог `/box-init` говорит, что сервис переехал в `claude-box.yml`, и называет к удалению строки, которые убрал `sed`; в `.claude/settings.json` из правил о compose-файлах и `claude-box.yml` осталось одно, `Edit(/claude-box.yml)`, — или итог называет эти правки файла руками;
- Claude в каждом проекте называет адрес сервиса `db`;
- движок в каждом проекте останавливается словом «готово», `cat hello.txt` печатает `hello`, в `git log` — коммиты итерации.

5. Уборка — после проверки: база и сети тестовых проектов, папки тестовых проектов и прошлых проб этой задачи, истории сессий тестовых проектов.

```bash
cd /tmp/boxlive/boxlive-main && docker compose down
cd /tmp/boxlive/boxlive-old && docker compose down
cd ~ && rm -rf /tmp/boxlive /tmp/compose-local-1usP /tmp/wt-probe-shog /tmp/wt-probe-scripts
rm -rf ~/.claude-box/.claude/projects/-workspace-boxlive*
```

Как ответить: допиши в конец файла docs/tasks/compose-local.md строку, которая начинается с «ответ:», и после двоеточия — сам ответ: «всё сходится» или что разошлось с ожиданием, с текстом ошибки или итога сессии. Потом запусти в Claude /box-next compose-local или в терминале agent-loop.sh --host compose-local.
