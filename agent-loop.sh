#!/usr/bin/env bash
# Движок автоцикла: итерации /box-next по задаче проекта, пока статус таск-файла «в работе».
# Запуск на хосте из папки проекта: ~/<клон agent-box>/agent-loop.sh <задача>
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

# уведомление в Telegram, когда известны токен и chat_id (tg=1)
tg=
notify() {
  [ -n "$tg" ] || return 0
  local text="$project: $1" resp
  resp=$(tg_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=${text:0:4000}")
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

[ $# -eq 1 ] && [ -n "$1" ] || { echo 'запуск: agent-loop.sh <задача>' >&2; exit 2; }
task=$1
for cmd in git jq claude; do
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

i=0
idle=0
while :; do
  st=$(sed -n '1s/^статус: *//p' "$file")
  case $st in
    'в работе') ;;
    блокер) stop 1 "задача $task — блокер
$(sed -n '/^## Блокер/,$p' "$file")" ;;
    готово) stop 0 "задача $task — готово" ;;
    *) stop 1 "задача $task — статус «$st» вне протокола" ;;
  esac
  [ "$idle" -lt "$max_idle" ] || stop 1 "задача $task — $max_idle итерации подряд без прогресса: проверить журнал и «Контекст», затем запустить снова"
  [ "$i" -lt "$max_iter" ] || stop 0 "задача $task — лимит $max_iter итераций за запуск; статус «в работе», следующий запуск продолжит"
  if [ "$i" -gt 0 ]; then
    say "пауза $pause с — Ctrl+C останавливает цикл чисто"
    sleep "$pause"
    [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C в паузе: итерация $i закоммичена"
  fi

  i=$((i + 1))
  head=$(git rev-parse HEAD)
  # идентификатор сессии задаётся до запуска: его называет алерт таймера, пока итерация идёт
  sid=$(cat /proc/sys/kernel/random/uuid)
  resume="сессия $sid — claude --resume $sid"
  say "задача $task — итерация $i/$max_iter, $(date +%H:%M), сессия $sid"

  # таймер итерации: порог пройден — алерт, итерация идёт дальше
  (
    trap 'kill $! 2>/dev/null; exit' TERM
    sleep "$alert" &
    wait
    msg="задача $task — итерация $i идёт дольше $((alert / 60)) мин, сессия $sid; итерация продолжается"
    say "$msg"
    notify "$msg"
  ) &
  timer=$!
  CONTEXT_GUARD_MODE=protocol claude -p "/box-next $task" --session-id "$sid" --permission-mode auto \
    --permission-prompts none --output-format json --max-turns "$max_turns" >"$tmp/out" 2>"$tmp/err"
  code=$?
  kill "$timer" 2>/dev/null

  # итог итерации: JSON на stdout; ненулевой код, is_error или stdout без JSON — провал.
  # -s ловит и пустой stdout: jq 1.6 с одним -e пропускает его с кодом 0
  json=0
  jq -se 'length == 1 and (.[0] | type == "object")' "$tmp/out" >/dev/null 2>&1 && json=1
  [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C во время итерации $i: в дереве могут быть правки без коммита, git status
$resume"
  if [ "$json" = 0 ]; then
    resume="итога JSON нет; если сессия успела начаться — claude --resume $sid"
    error=$(tail -n 5 "$tmp/err")
    stop 1 "итерация $i упала: код $code, $resume${error:+
$error}"
  fi
  if [ "$code" != 0 ] || [ "$(jq -r '.is_error' "$tmp/out")" != false ]; then
    error=$(jq -r '(.result // empty), (.errors // [] | .[])' "$tmp/out")
    stop 1 "итерация $i упала: код $code, terminal_reason $(jq -r '.terminal_reason' "$tmp/out")${error:+
$error}
$resume"
  fi

  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || stop 1 "итерация $i оставила правки без коммита:
$dirty
$resume"
  say "итерация $i закончена: ходов $(jq -r '.num_turns' "$tmp/out"), сессия $sid"

  # прогресс: закрыт чекбокс очереди или дифф итерации шире служебных файлов завершения
  if [ "$(closed <"$file")" -gt "$(git show "$head:$file" 2>/dev/null | closed)" ] ||
    git diff --name-only "$head" HEAD | grep -qvxF -e "$file" -e docs/JOURNAL.md -e docs/DECISIONS.md; then
    idle=0
  else
    idle=$((idle + 1))
  fi
done
