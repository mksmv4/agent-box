#!/usr/bin/env bash
# Движок автоцикла: итерации /box-next по задаче проекта, пока статус таск-файла «в работе».
# Запуск на хосте из папки проекта: ~/<клон agent-box>/agent-loop.sh <задача>
# Код выхода: 0 — «готово» или лимит итераций; 1 — остановка, ждущая пользователя; 2 — движок не запустился; 130 — Ctrl+C.
set -u

max_iter=10   # итераций за запуск
pause=10      # секунд между итерациями — окно чистой остановки Ctrl+C
max_idle=3    # итераций подряд без прогресса
max_turns=200 # потолок ходов итерации

say() { printf 'agent-loop: %s\n' "$*"; }

# остановка цикла: сообщение в терминал и код выхода
stop() {
  local code=$1
  shift
  say "$@"
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
  say "задача $task — итерация $i/$max_iter, $(date +%H:%M)"
  CONTEXT_GUARD_MODE=protocol claude -p "/box-next $task" --permission-mode auto \
    --permission-prompts none --output-format json --max-turns "$max_turns" >"$tmp/out" 2>"$tmp/err"
  code=$?

  # итог итерации: JSON на stdout; ненулевой код, is_error или stdout без JSON — провал.
  # -s ловит и пустой stdout: jq 1.6 с одним -e пропускает его с кодом 0
  if jq -se 'length == 1 and (.[0] | type == "object")' "$tmp/out" >/dev/null 2>&1; then
    sid=$(jq -r '.session_id' "$tmp/out")
    resume="сессия $sid — claude --resume $sid"
  else
    sid=
    resume="итога JSON нет, сессия — в списке claude --resume в папке проекта"
  fi
  [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C во время итерации $i: в дереве могут быть правки без коммита, git status
$resume"
  if [ -z "$sid" ]; then
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
