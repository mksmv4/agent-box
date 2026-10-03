#!/usr/bin/env bash
# Движок автоцикла: итерации /box-next по задаче проекта, пока статус таск-файла «в работе» или «блокер» с ответом пользователя.
# Запуск на хосте из папки проекта: agent-loop.sh [--host] <задача>
# Первый раз на машине — ./agent-loop.sh в папке клона: скрипт ставит себя командой agent-loop.sh ссылкой в ~/.local/bin.
# Итерации идут в контейнере — сервисе claude проекта; --host — итерации claude хоста.
# Уведомления в Telegram — при TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в ~/.config/agent-loop.env, иначе остановки видны только в терминале.
# Код выхода: 0 — «готово» или лимит итераций; 1 — остановка, ждущая пользователя; 2 — движок не запустился; 130 — Ctrl+C.
set -u

max_iter=10   # итераций за запуск
pause=10      # секунд между итерациями — окно чистой остановки Ctrl+C
max_idle=3    # итераций подряд без прогресса
max_turns=200 # потолок ходов итерации
alert=3600    # секунд итерации до алерта таймера

say() { printf 'agent-loop: %s\n' "$*"; }

# запрос к Telegram Bot API: метод и поля запроса; токен уходит в curl через stdin и в списке процессов не виден
tg_api() {
  local method=$1
  shift
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$method" |
    curl -sS --max-time 10 -K - "$@" 2>&1
}

# уведомление в Telegram, когда известны токен и chat_id (tg=1).
# Текст до 4000 символов — сообщением: предел Telegram 4096. Длиннее — файлом .md целиком;
# в подписи (предел 1024) — начало текста и последняя строка: там сказано, что делать дальше
tg=
notify() {
  [ -n "$tg" ] || return 0
  local text="$project: $1" resp last
  if [ "${#text}" -le 4000 ]; then
    resp=$(tg_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text")
  else
    last=${text##*$'\n'}
    printf '%s\n' "$text" >"$tmp/notify.md"
    resp=$(tg_api sendDocument --form-string "chat_id=$TELEGRAM_CHAT_ID" \
      --form-string "caption=${text:0:600}…"$'\n'"${last:0:400}" \
      -F "document=@$tmp/notify.md;filename=$project-$task.md")
  fi
  jq -e .ok <<<"$resp" >/dev/null 2>&1 ||
    say "уведомление в Telegram не ушло: $(jq -r .description <<<"$resp" 2>/dev/null || printf %s "$resp")"
}

# остановка цикла: сообщение в терминал, уведомление и код выхода; отказ запуска (код 2) — только в терминал
stop() {
  local code=$1
  shift
  say "$@"
  [ "$code" = 2 ] || notify "$*"
  exit "$code"
}

# команда agent-loop.sh по имени: ссылка на этот скрипт в ~/.local/bin; папки нет в PATH — запуск полным адресом.
# Ссылка от перенесённого клона заменяется. me — команда запуска в подсказках движка
me=agent-loop.sh
if ! command -v agent-loop.sh >/dev/null; then
  self=$(realpath "$0")
  case ":$PATH:" in
    *":$HOME/.local/bin:"*)
      mkdir -p ~/.local/bin && ln -sf "$self" ~/.local/bin/agent-loop.sh &&
        say "agent-loop.sh теперь запускается по имени из любой папки" ;;
    *)
      me=$self
      say "папки ~/.local/bin нет в PATH — запуск полным адресом" ;;
  esac
fi

host=
[ "${1:-}" = --host ] && { host=1; shift; }
[ $# -eq 0 ] && { say "запуск из папки проекта: $me [--host] <задача>"; exit 0; }
[ $# -eq 1 ] && [ -n "$1" ] || { echo "запуск: $me [--host] <задача>" >&2; exit 2; }
task=$1
again="$me${host:+ --host} $task"
run=docker
[ -z "$host" ] || run=claude
for cmd in git jq "$run"; do
  command -v "$cmd" >/dev/null || stop 2 "нет команды $cmd"
done
root=$(git rev-parse --show-toplevel 2>/dev/null) || stop 2 "папка вне git-репозитория: $PWD"
cd "$root" || exit 2
file=docs/tasks/$task.md
[ -f "$file" ] || stop 2 "нет таск-файла $file"
project=$(basename "$root")

# токен и chat_id — из файла вне репозиториев; берутся только эти две строки, в окружение сессий они не попадают.
# chat_id, которого нет в файле, берётся из последнего сообщения боту и дописывается в файл
env=~/.config/agent-loop.env
if [ -f "$env" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    value=${value#[\"\']}
    value=${value%[\"\']}
    case $key in TELEGRAM_BOT_TOKEN | TELEGRAM_CHAT_ID) printf -v "$key" %s "$value" ;; esac
  done <"$env"
fi
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  command -v curl >/dev/null || stop 2 "нет команды curl для уведомлений в Telegram"
  if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    TELEGRAM_CHAT_ID=$(tg_api getUpdates | jq -r '.result | map(.message.chat.id // empty) | last // empty' 2>/dev/null)
    if [ -n "$TELEGRAM_CHAT_ID" ]; then
      printf '\nTELEGRAM_CHAT_ID=%s\n' "$TELEGRAM_CHAT_ID" >>"$env"
      say "chat_id $TELEGRAM_CHAT_ID взят из последнего сообщения боту и записан в $env"
    fi
  fi
  if [ -n "$TELEGRAM_CHAT_ID" ]; then
    tg=1
  else
    say "уведомления в Telegram выключены: chat_id не найден — напиши боту любое сообщение в Telegram и запусти снова"
  fi
else
  say "уведомления в Telegram выключены: в $env нет TELEGRAM_BOT_TOKEN"
fi

# lock репозитория: имя задачи и PID цикла; lock процесса, которого уже нет, перехватывается
lock=$(git rev-parse --absolute-git-dir)/agent-loop.lock
if ! (set -o noclobber; echo "$task $$" >"$lock") 2>/dev/null; then
  other= pid=
  read -r other pid <"$lock"
  kill -0 "$pid" 2>/dev/null && stop 2 "в репозитории уже идёт цикл задачи $other (PID $pid, $lock)"
  echo "$task $$" >"$lock"
fi
tmp=$(mktemp -d)
trap 'rm -f "$lock"; rm -rf "$tmp"' EXIT

# Ctrl+C: терминал шлёт SIGINT движку и идущей сессии claude; движок замечает его, когда команда вернётся
interrupted=0
trap 'interrupted=1' INT

# число закрытых чекбоксов очереди в «Постановке» таск-файла со stdin
closed() { sed -n '/^## Постановка/,/^## /p' | grep -c '^- \[x\]'; }

# ответ пользователя на блокер: строка «ответ:» в секции «Блокер» в любом регистре.
# Регистр кириллицы grep сводит в UTF-8 локали, в локали C совпадает только «ответ:»
answered() { sed -n '/^## Блокер/,$p' "$file" | grep -qi '^ответ:'; }

i=0
idle=0
while :; do
  st=$(sed -n '1s/^статус: *//p' "$file")
  case $st in
    'в работе') ;;
    блокер)
      # секция кончается строкой «Как ответить:» сессии — она последняя строка уведомления
      answered || stop 1 "задача $task — блокер
$(sed -n '/^## Блокер/,$p' "$file")"
      # блокер с ответом снят: статус «в работе» в рабочем дереве, его забирает коммит итерации
      sed -i '1s/.*/статус: в работе/' "$file"
      say "задача $task — ответ на блокер найден, статус «в работе»"
      ;;
    готово) stop 0 "задача $task — готово
дальше: проверить сделанное по docs/JOURNAL.md и хвостам «Контекста» $file, затем чекбокс строке задачи в docs/ROADMAP.md" ;;
    *) stop 1 "задача $task — статус «$st» вне протокола
дальше: первая строка $file — «статус: в работе», «статус: блокер» или «статус: готово»; затем $again снова" ;;
  esac
  [ "$idle" -lt "$max_idle" ] || stop 1 "задача $task — $max_idle итерации подряд без прогресса
дальше: проверить docs/JOURNAL.md и «Контекст» $file, затем $again снова"
  [ "$i" -lt "$max_iter" ] || stop 0 "задача $task — лимит $max_iter итераций за запуск, статус «в работе»
дальше: $again снова — следующий запуск продолжит"
  if [ "$i" -gt 0 ]; then
    say "пауза $pause с — Ctrl+C останавливает цикл чисто"
    sleep "$pause"
    [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C в паузе: итерация $i закоммичена
дальше: $again снова — следующий запуск продолжит"
  elif [ -z "$host" ]; then
    # сервис claude проекта — перед первой итерацией в контейнере
    services=$(docker compose --profile claude config --services 2>&1)
    grep -qx claude <<<"$services" || stop 2 "нет сервиса claude в compose-файле проекта — его кладёт /box-init; итерации на хосте — $me --host $task
$services"
  fi

  i=$((i + 1))
  head=$(git rev-parse HEAD)
  # идентификатор сессии задаётся до запуска: его называет алерт таймера, пока итерация идёт.
  # Сессии контейнера лежат в его домашней папке — доследование тоже через сервис claude
  sid=$(cat /proc/sys/kernel/random/uuid)
  resume="claude --resume $sid"
  [ -n "$host" ] || resume="docker compose run --rm $resume"
  say "задача $task — итерация $i/$max_iter, $(date +%H:%M), сессия $sid"

  # таймер итерации: порог пройден — алерт, итерация идёт дальше
  (
    trap 'kill $! 2>/dev/null; exit' TERM
    sleep "$alert" &
    wait
    msg="задача $task — итерация $i идёт дольше $((alert / 60)) мин, сессия $sid; итерация продолжается
дальше: ждать; вмешательство — $resume или Ctrl+C в терминале движка"
    say "$msg"
    notify "$msg"
  ) &
  timer=$!
  args=(-p "/box-next $task" --session-id "$sid" --permission-mode auto --permission-prompts none
    --output-format json --max-turns "$max_turns")
  # контейнер: -T — stdout с JSON итога отдельно от stderr; ввод — /dev/null: -p добавляет поданный ввод к промпту,
  # а открытый ввод контейнера не кончается; --progress quiet — в stderr только ошибки.
  # Код выхода claude compose возвращает; на Ctrl+C отдаёт SIGINT сессии и сам выходит с 130, не дожидаясь итога
  if [ -n "$host" ]; then
    CONTEXT_GUARD_MODE=protocol claude "${args[@]}"
  else
    docker compose --progress quiet run --rm -T -e CONTEXT_GUARD_MODE=protocol claude "${args[@]}" </dev/null
  fi >"$tmp/out" 2>"$tmp/err"
  code=$?
  kill "$timer" 2>/dev/null

  # итог итерации: JSON на stdout; ненулевой код, is_error или stdout без JSON — провал.
  # -s ловит и пустой stdout: jq 1.6 с одним -e пропускает его с кодом 0
  json=0
  jq -se 'length == 1 and (.[0] | type == "object")' "$tmp/out" >/dev/null 2>&1 && json=1
  [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C во время итерации $i: в дереве могут быть правки без коммита
дальше: git status, доследование — $resume; затем $again снова"
  if [ "$json" = 0 ]; then
    error=$(tail -n 5 "$tmp/err")
    stop 1 "итерация $i упала: код $code, итога JSON нет${error:+
$error}
дальше: доследование — $resume, если сессия успела начаться; затем $again снова"
  fi
  if [ "$code" != 0 ] || [ "$(jq -r '.is_error' "$tmp/out")" != false ]; then
    error=$(jq -r '(.result // empty), (.errors // [] | .[])' "$tmp/out")
    stop 1 "итерация $i упала: код $code, terminal_reason $(jq -r '.terminal_reason' "$tmp/out")${error:+
$error}
дальше: доследование — $resume; затем $again снова"
  fi

  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || stop 1 "итерация $i оставила правки без коммита:
$dirty
дальше: доследование — $resume; правки закоммитить или откатить, затем $again снова"
  say "итерация $i закончена: ходов $(jq -r '.num_turns' "$tmp/out"), сессия $sid"

  # прогресс: закрыт чекбокс очереди или дифф итерации шире служебных файлов завершения
  if [ "$(closed <"$file")" -gt "$(git show "$head:$file" 2>/dev/null | closed)" ] ||
    git diff --name-only "$head" HEAD | grep -qvxF -e "$file" -e docs/JOURNAL.md -e docs/DECISIONS.md; then
    idle=0
  else
    idle=$((idle + 1))
  fi
done
