#!/usr/bin/env bash
# Движок автоцикла: итерации /box-next по задаче проекта, пока статус таск-файла «в работе» или «блокер» с ответом пользователя.
# Запуск на хосте из папки проекта: agent-loop.sh [--host | --no-firewall] [--quiet] <задача>; из любой папки — путём к таск-файлу: agent-loop.sh [--host | --no-firewall] [--quiet] <проект>/docs/tasks/<задача>.md
# Первый раз на машине — ./agent-loop.sh в папке клона: скрипт ставит себя и box-connect командами ссылками в ~/.local/bin.
# Итерации идут в контейнере — сервисе claude из claude-box.yml проекта: сеть ограничена списком адресов, режим без вопросов о разрешениях;
# --no-firewall — сеть контейнера открыта, режим auto; --host — итерации claude хоста в режиме auto.
# Уведомления в Telegram — при TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в ~/.config/agent-loop.env, иначе остановки видны только в терминале;
# --quiet — остановки только в терминале и при настроенном боте.
# Журнал цикла — .git/agent-loop.log проекта, путь — в строке старта: запуски, итерации с ходом сессии, остановки.
# Пределы цикла — config.yml рядом с движком в клоне agent-box, один на все проекты, строки «ключ: целое число»; нет файла или ключа — значение по умолчанию ниже.
# Код выхода: 0 — «готово» или лимит итераций; 1 — остановка, ждущая пользователя; 2 — движок не запустился; 130 — Ctrl+C.
# Правило песочницы claude-box для сессии Claude хоста, которая ведёт движок, — agent-loop.sh --sandbox-rule человеком в терминале, раз на машину:
# исключение классификатора режима auto в ~/.claude/settings.json; повторный запуск заменяет его. Код выхода: 0 — Claude Code видит правило; 1 — не видит; 2 — не записано.
set -u

# пределы цикла по умолчанию; поверх — config.yml клона
max_iter=10   # итераций за запуск
pause=10      # секунд между итерациями — окно чистой остановки Ctrl+C
max_idle=3    # итераций подряд без прогресса
max_turns=200 # потолок ходов итерации
alert=60      # минут итерации до алерта таймера

say() { printf 'agent-loop: %s\n' "$*"; }

# git хоста по репозиторию проекта: команда fsmonitor и хуки из его .git выключены — их может подложить агент контейнера
g() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }

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

# строка журнала цикла: дата и время, строки продолжения — с отступом.
# До захвата lock журнал — /dev/null: отказ второго запуска в журнал идущего цикла не попадает
log=/dev/null
logl() { printf '%s %s\n' "$(date '+%F %T')" "$*" | sed '2,$s/^/    /' >>"$log"; }

# остановка цикла: сообщение в терминал и журнал, уведомление и код выхода; отказ запуска (код 2) — без уведомления
stop() {
  local code=$1
  shift
  say "$@"
  logl "остановка: $*"
  [ "$code" = 2 ] || notify "$*"
  exit "$code"
}

# правило песочницы claude-box в исключения классификатора режима auto личных настроек Claude Code хоста: блок autoMode
# классификатор читает оттуда, настройки проекта ему закрыты. Запись своих разрешений сессия хоста в режиме auto получает с отказом — пишет человек
sandbox_rule() {
  local f=~/.claude/settings.json label='Claude-box Sandbox:' rule bak new seen cmd
  rule="$label запуск Claude Code в песочнице claude-box разрешён и не считается Create Unsafe Agents — docker compose -f <compose-файл в корне проекта> run ... --entrypoint claude-box-firewall ... claude <аргументы>, в том числе с -p, --resume, --session-id и --permission-mode bypassPermissions. Контейнер сервиса claude — песочница: исходящая сеть ограничена списком адресов, процесс под обычным пользователем, с хоста подключены папка проекта, отдельная домашняя папка контейнера ~/.claude-box и домашняя папка хоста — только на чтение и закрыта процессу агента. Правило не покрывает запуск без точки входа claude-box-firewall и команды с -v/--volume, --user, --privileged, --cap-add, --env-from-file, -e/--env с переменными, кроме CONTEXT_GUARD_MODE и CLAUDE_CODE_PROMPT_CACHE_TTL, или compose-файлом вне корня проекта."
  for cmd in jq claude; do
    command -v "$cmd" >/dev/null || stop 2 "нет команды $cmd"
  done
  # копия настроек с датой рядом: первая копия дня остаётся при повторных запусках; файла нет — он создаётся
  bak=$f.bak-$(date +%F)
  if [ -e "$f" ]; then
    [ -e "$bak" ] || cp "$f" "$bak" || stop 2 "копия $bak не записана, настройки не тронуты"
  else
    mkdir -p ~/.claude && printf '{}\n' >"$f" || stop 2 "файл $f не создан"
    say "файла $f не было — он создан"
    bak=
  fi
  # запись с меткой заменяется текущей; встроенные исключения — строкой "$defaults" в начале, пока своего списка нет:
  # список без неё заменяет встроенные целиком. Запись — поверх файла: ссылка на файл и его права остаются
  new=$(mktemp)
  jq --arg l "$label" --arg r "$rule" \
    '.autoMode.allow = [((.autoMode.allow // ["$defaults"])[] | select(startswith($l) | not)), $r]' \
    "$f" >"$new" || { rm -f "$new"; stop 2 "настройки $f не прочитаны как JSON — правило не записано, файл не тронут"; }
  cp "$new" "$f" || { rm -f "$new"; stop 2 "запись в $f не удалась"; }
  rm -f "$new"
  say "правило записано в $f${bak:+; копия настроек до первой правки за день — $bak}"
  # правило глазами Claude Code
  seen=$(claude auto-mode config | jq -r --arg l "$label" '.allow[]? | select(startswith($l))')
  [ -n "$seen" ] || stop 1 "правило не применилось: в claude auto-mode config его нет"
  say "Claude Code видит правило (claude auto-mode config):"
  printf '%s\n' "$seen"
  exit 0
}

# команды agent-loop.sh и box-connect по имени: ссылки на скрипты клона в ~/.local/bin; папки нет в PATH — запуск полным адресом.
# Ссылки от перенесённого клона заменяются. me — команда запуска в подсказках движка; self — сам скрипт в клоне, рядом с ним конфиг
me=agent-loop.sh
self=$(realpath "$0")
if ! command -v agent-loop.sh >/dev/null || ! command -v box-connect >/dev/null; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*)
      mkdir -p ~/.local/bin && ln -sf "$self" ~/.local/bin/agent-loop.sh &&
        ln -sf "$(dirname "$self")"/box-connect ~/.local/bin/box-connect &&
        say "agent-loop.sh и box-connect теперь запускаются по имени из любой папки" ;;
    *)
      me=$self
      say "папки ~/.local/bin нет в PATH — запуск полным адресом" ;;
  esac
fi

host= open= quiet=
while :; do
  case ${1:-} in
    --host) host=1 ;;
    --no-firewall) open=1 ;;
    --quiet) quiet=1 ;;
    *) break ;;
  esac
  shift
done
usage="запуск: $me [--host | --no-firewall] [--quiet] <задача> из папки проекта или $me [--host | --no-firewall] [--quiet] <путь к таск-файлу> из любой папки; правило песочницы claude-box для сессии Claude хоста — $me --sandbox-rule"
[ $# -eq 0 ] && { say "$usage"; exit 0; }
if [ "$1" = --sandbox-rule ]; then
  [ $# -eq 1 ] && [ -z "$host$open$quiet" ] || { echo "$usage" >&2; exit 2; }
  sandbox_rule
fi
[ $# -eq 1 ] && [ -n "$1" ] || { echo "$usage" >&2; exit 2; }
# задача — имя или путь к таск-файлу; путь задаёт и проект — git-репозиторий файла, подсказки повторяют запуск полным путём
path=
case $1 in
  */* | *.md)
    [ -f "$1" ] || stop 2 "нет таск-файла $1"
    path=$(realpath "$1")
    task=$(basename "$path" .md)
    cd "$(dirname "$path")" || exit 2
    ;;
  *) task=$1 ;;
esac
target=${path:-$task}
again="$me${host:+ --host}${open:+ --no-firewall}${quiet:+ --quiet} $target"
run=docker
[ -z "$host" ] || run=claude
for cmd in git jq "$run"; do
  command -v "$cmd" >/dev/null || stop 2 "нет команды $cmd"
done
root=$(g rev-parse --show-toplevel 2>/dev/null) || stop 2 "папка вне git-репозитория: $PWD"
cd "$root" || exit 2
file=docs/tasks/$task.md
[ -z "$path" ] || [ "$(realpath "$file" 2>/dev/null)" = "$path" ] || stop 2 "таск-файл $path вне docs/tasks/ проекта $root"
[ -f "$file" ] || stop 2 "нет таск-файла $file"
project=$(basename "$root")

# пределы цикла из config.yml клона, рядом с движком, — один раз на запуск: строка «ключ: значение», комментарии # и пустые строки пропускаются.
# split_chars — порог раздела документации для /box-init и сессий, check_agent_model — модель агента проверок оркестратора: движку они не нужны, у модели проверяется вид значения.
# Неизвестный ключ или значение не того вида — отказ запуска с номером строки
conf=$(dirname "$self")/config.yml
from=
if [ -f "$conf" ]; then
  n=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    line=${raw%%#*}
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^([a-z_]+):[[:space:]]*([^[:space:]]*)[[:space:]]*$ ]] ||
      stop 2 "$conf, строка $n: «$raw» — нужна строка вида «ключ: значение»"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case $key in
      max_iterations) var=max_iter ;;
      pause_seconds) var=pause ;;
      max_idle_iterations) var=max_idle ;;
      max_turns) var=max_turns ;;
      alert_minutes) var=alert ;;
      split_chars) var= ;;
      check_agent_model)
        [[ $value =~ ^[a-z]+$ ]] || stop 2 "$conf, строка $n: у ключа $key значение «$value» — нужен алиас модели: opus, sonnet, haiku или fable"
        continue ;;
      *) stop 2 "$conf, строка $n: неизвестный ключ «$key» — известные: max_iterations, pause_seconds, max_idle_iterations, max_turns, alert_minutes, split_chars, check_agent_model" ;;
    esac
    [[ $value =~ ^[0-9]+$ ]] || stop 2 "$conf, строка $n: у ключа $key значение «$value» — нужно целое число"
    [ -z "$var" ] || { printf -v "$var" %d "$((10#$value))"; from+=" $var"; }
  done <"$conf"
fi
# строка старта: действующие пределы по источнику — путь конфига или значение по умолчанию
own= def=
for d in max_iter:'итераций за запуск %s' pause:'пауза %s с' max_idle:'итераций подряд без прогресса %s' max_turns:'ходов итерации %s' alert:'алерт таймера через %s мин'; do
  var=${d%%:*}
  printf -v item "${d#*:}" "${!var}"
  case "$from " in
    *" $var "*) own+=${own:+, }$item ;;
    *) def+=${def:+, }$item ;;
  esac
done
none=
[ -f "$conf" ] || none=" ($conf нет)"
say "пределы цикла${own:+ из $conf: $own}${own:+${def:+;}}${def:+ по умолчанию$none: $def}"

# сервис claude — в claude-box.yml проекта явным -f: контейнер собирается только по нему, основной compose-файл проекта, дополнения и COMPOSE_FILE из .env в сборку не входят
cf=claude-box.yml
[ -n "$host" ] || [ -f "$cf" ] || stop 2 "нет $cf в корне проекта — его кладёт /box-init; итерации на хосте — $me --host $target"

# режим итераций: в контейнере без --no-firewall — точка входа claude-box-firewall ограничивает сеть, и вопросов о разрешениях нет
mode=auto
fw=()
if [ -z "$host" ]; then
  if [ -z "$open" ]; then
    mode=bypassPermissions
    fw=(--entrypoint claude-box-firewall)
    say "итерации в контейнере: сеть ограничена списком адресов, режим без вопросов о разрешениях"
  else
    say "итерации в контейнере: сеть открыта, режим auto"
  fi
fi

# токен и chat_id — из файла вне репозиториев; берутся только эти две строки, в окружение сессий они не попадают.
# Токен проверяется запросом getMe до первой итерации, пока пользователь у терминала: неверный токен вида <число>:<ключ>
# Telegram отклоняет ответом 401 «Unauthorized», токен другого вида — 404 «Not Found»; прочий сбой проверки уведомления не выключает.
# chat_id, которого нет в файле, берётся из последнего сообщения боту и дописывается в файл.
# --quiet выключает Telegram на запуск целиком, вместе с проверкой токена
env=~/.config/agent-loop.env
if [ -f "$env" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    value=${value#[\"\']}
    value=${value%[\"\']}
    case $key in TELEGRAM_BOT_TOKEN | TELEGRAM_CHAT_ID) printf -v "$key" %s "$value" ;; esac
  done <"$env"
fi
if [ -n "$quiet" ]; then
  say "уведомления в Telegram выключены флагом --quiet: остановки — только в терминале"
elif [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  command -v curl >/dev/null || stop 2 "нет команды curl для уведомлений в Telegram"
  resp=$(tg_api getMe)
  check=$(jq -r 'if .ok then "ok" else .error_code end' <<<"$resp" 2>/dev/null)
  why=$(jq -r .description <<<"$resp" 2>/dev/null) || why=$resp
  case $check in
    401 | 404)
      say "уведомления в Telegram выключены: неверный токен, Telegram ответил «$why» — поправь строку TELEGRAM_BOT_TOKEN в $env: токен от @BotFather целиком, вместе с двоеточием" ;;
    *)
      [ "$check" = ok ] || say "токен Telegram не проверен, уведомления остаются включены: $why"
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
      fi ;;
  esac
else
  say "уведомления в Telegram выключены: в $env нет TELEGRAM_BOT_TOKEN"
fi

# lock репозитория: имя задачи и PID цикла; lock процесса, которого уже нет, перехватывается
lock=$(g rev-parse --absolute-git-dir)/agent-loop.lock
if ! (set -o noclobber; echo "$task $$" >"$lock") 2>/dev/null; then
  other= pid=
  read -r other pid <"$lock"
  kill -0 "$pid" 2>/dev/null && stop 2 "в репозитории уже идёт цикл задачи $other (PID $pid, $lock)"
  echo "$task $$" >"$lock"
fi
tmp=$(mktemp -d)
mark=
trap 'rm -f "$lock"; rm -rf "$tmp"; [ -z "$mark" ] || kill "$mark" 2>/dev/null' EXIT

# журнал цикла — рядом с lock-файлом, вне рабочего дерева; файл копится от запуска к запуску
log=$(dirname "$lock")/agent-loop.log
say "журнал цикла: $log"
logl "запуск: $again"

# Ctrl+C: терминал шлёт SIGINT движку и идущей сессии claude; движок замечает его, когда команда вернётся
interrupted=0
trap 'interrupted=1' INT

# число закрытых чекбоксов очереди в «Постановке» таск-файла со stdin
closed() { sed -n '/^## Постановка/,/^## /p' | grep -c '^- \[x\]'; }

# ответ на блокер — пользователя или оркестратора: строка «ответ:» в секции «Блокер» в любом регистре.
# Регистр кириллицы grep сводит в UTF-8 локали, в локали C совпадает только «ответ:»
answered() { sed -n '/^## Блокер/,$p' "$file" | grep -qi '^ответ:'; }

# ход итерации в журнал: из ответов агента в истории сессии Claude Code (jsonl) — текст, чтение и правка файлов,
# команды, поиск, прочие инструменты по имени; пути — от корня проекта сессии, длинное обрезается
progress='fromjson? | select(.type == "assistant" and (.isSidechain | not))
  | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdate | strflocaltime("%F %T")) as $t | (.cwd + "/") as $root
  | def rel: ltrimstr($root); def short: gsub("\\s+"; " ") | if length > 200 then .[0:200] + "…" else . end;
  .message.content[]? | .input as $in
  | if .type == "text" then "агент: " + (.text | short)
    elif .type != "tool_use" then empty
    elif .name == "Read" then "читает " + ($in.file_path | rel)
    elif .name == "Edit" or .name == "Write" or .name == "NotebookEdit" then "правит " + ($in.file_path // $in.notebook_path | rel)
    elif .name == "Bash" then "команда: " + ($in.command | short)
    elif .name == "Grep" or .name == "Glob" then "ищет " + $in.pattern + ($in.path // "" | rel | if . == "" then "" else " в " + . end)
    else .name + " " + ($in | tostring | short) end
  | "\($t)   \(.)"'

# история сессии — у контейнера в его домашней папке ~/.claude-box, у хоста в ~/.claude; файл появляется со стартом сессии.
# Метка — процесс на время итерации: со смертью метки tail дочитывает файл и выходит
follow() {
  local dir=~/.claude/projects f= last=
  [ -n "$host" ] || dir=~/.claude-box/.claude/projects
  while :; do
    kill -0 "$mark" 2>/dev/null || last=1
    f=$(find "$dir" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)
    [ -z "$f" ] || break
    [ -z "$last" ] || return 0
    sleep 1
  done
  tail -n +1 -f --pid="$mark" "$f" | jq --unbuffered -Rr "$progress" >>"$log" 2>/dev/null
}

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
дальше: проверить ход итераций в журнале цикла $log и «Контекст» $file, затем $again снова"
  [ "$i" -lt "$max_iter" ] || stop 0 "задача $task — лимит $max_iter итераций за запуск, статус «в работе»
дальше: $again снова — следующий запуск продолжит"
  if [ "$i" -gt 0 ]; then
    say "пауза $pause с — Ctrl+C останавливает цикл чисто"
    sleep "$pause"
    [ "$interrupted" = 0 ] || stop 130 "остановлен Ctrl+C в паузе: итерация $i закоммичена
дальше: $again снова — следующий запуск продолжит"
  elif [ -z "$host" ]; then
    # сервис claude проекта — перед первой итерацией в контейнере
    services=$(docker compose -f "$cf" --profile claude config --services 2>&1)
    grep -qx claude <<<"$services" || stop 2 "нет сервиса claude в $cf — его кладёт /box-init; итерации на хосте — $me --host $target
$services"
  fi

  i=$((i + 1))
  head=$(g rev-parse HEAD)
  # идентификатор сессии задаётся до запуска: его называет алерт таймера, пока итерация идёт.
  # Сессии контейнера лежат в его домашней папке — доследование тоже через сервис claude
  sid=$(cat /proc/sys/kernel/random/uuid)
  resume="claude --resume $sid"
  [ -n "$host" ] || resume="docker compose -f $cf run --rm $resume"
  say "задача $task — итерация $i/$max_iter, $(date +%H:%M), сессия $sid"
  # начало итерации в журнал: шаг очереди — первый незакрытый чекбокс «Постановки», номер из их числа, начало текста
  queue=$(sed -n '/^## Постановка/,/^## /p' "$file" | grep '^- \[[ x]\]')
  step=$(grep -m1 '^- \[ \]' <<<"$queue")
  step=${step#- \[ \] }
  [ "${#step}" -le 80 ] || step="${step:0:80}…"
  logl "задача $task — итерация $i/$max_iter, шаг $(($(closed <"$file") + 1))/$(grep -c . <<<"$queue") «$step», сессия $sid"
  t0=$SECONDS

  # ход итерации — фоном, пока жива метка
  sleep infinity &
  mark=$!
  follow &
  follower=$!

  # таймер итерации: порог пройден — алерт, итерация идёт дальше
  (
    trap 'kill $! 2>/dev/null; exit' TERM
    sleep "$((alert * 60))" &
    wait
    msg="задача $task — итерация $i идёт дольше $alert мин, сессия $sid; итерация продолжается
дальше: ждать; вмешательство — $resume или Ctrl+C в терминале движка"
    say "$msg"
    logl "$msg"
    notify "$msg"
  ) &
  timer=$!
  args=(-p "/box-next $task" --session-id "$sid" --permission-mode "$mode" --permission-prompts none
    --output-format json --max-turns "$max_turns")
  # окружение итерации: сигнал context-guard — протокол молча; кэш промпта на пять минут вместо часового по умолчанию подписки — отсчёт идёт
  # от последнего вызова, вызовы внутри итерации идут чаще, а следующая итерация стартует новой сессией; запись в кэш на час стоит 2× входа, на пять минут — 1,25×.
  # контейнер: -T — stdout с JSON итога отдельно от stderr; ввод — /dev/null: -p добавляет поданный ввод к промпту,
  # а открытый ввод контейнера не кончается; --progress quiet — в stderr только ошибки; COMPOSE_IGNORE_ORPHANS убирает строку о контейнерах
  # основного compose-файла проекта: для claude-box.yml с тем же именем проекта Compose они чужие.
  # Код выхода claude compose возвращает; на Ctrl+C отдаёт SIGINT сессии и сам выходит с 130, не дожидаясь итога
  if [ -n "$host" ]; then
    CONTEXT_GUARD_MODE=protocol CLAUDE_CODE_PROMPT_CACHE_TTL=5m claude "${args[@]}"
  else
    COMPOSE_IGNORE_ORPHANS=true docker compose -f "$cf" --progress quiet run --rm -T "${fw[@]}" -e CONTEXT_GUARD_MODE=protocol -e CLAUDE_CODE_PROMPT_CACHE_TTL=5m claude "${args[@]}" </dev/null
  fi >"$tmp/out" 2>"$tmp/err"
  code=$?
  kill "$timer" 2>/dev/null
  # снятие метки: tail дочитывает ход и выходит. wait убирает процесс метки из таблицы процессов — неубранный tail считает живым
  kill "$mark" 2>/dev/null
  wait "$mark" 2>/dev/null
  mark=
  wait "$follower"

  # итог итерации: JSON на stdout; ненулевой код, is_error или stdout без JSON — провал.
  # -s ловит и пустой stdout: jq 1.6 с одним -e пропускает его с кодом 0
  json=0
  jq -se 'length == 1 and (.[0] | type == "object")' "$tmp/out" >/dev/null 2>&1 && json=1

  # конец итерации в журнал: длительность, исход — terminal_reason и ходы итога, статус задачи, коммиты итерации
  dur=$((SECONDS - t0))
  outcome="итога JSON нет"
  [ "$json" = 0 ] || outcome=$(jq -r '"\(.terminal_reason), ходов \(.num_turns)"' "$tmp/out")
  commits=$(g log --reverse --format='коммит %h %s' "$head"..HEAD)
  logl "итерация $i закончена за $((dur / 60)) мин $((dur % 60)) с: код $code, $outcome, статус «$(sed -n '1s/^статус: *//p' "$file")»${commits:+
$commits}"
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

  dirty=$(g status --porcelain)
  [ -z "$dirty" ] || stop 1 "итерация $i оставила правки без коммита:
$dirty
дальше: доследование — $resume; правки закоммитить или откатить, затем $again снова"
  say "итерация $i закончена: ходов $(jq -r '.num_turns' "$tmp/out"), сессия $sid"

  # прогресс: закрыт чекбокс очереди или дифф итерации шире служебных файлов завершения
  if [ "$(closed <"$file")" -gt "$(g show "$head:$file" 2>/dev/null | closed)" ] ||
    g diff --name-only "$head" HEAD | grep -qvxF -e "$file" -e docs/JOURNAL.md -e docs/DECISIONS.md; then
    idle=0
  else
    idle=$((idle + 1))
  fi
done
