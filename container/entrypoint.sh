#!/bin/sh
# Запуск Claude Code в контейнере claude-box; аргументы запуска уходят в claude.
# Старт от root: из домашней папки хоста переносится то, что там есть, затем Claude Code запускается от node с переменными .env проекта.
set -e

# домашняя папка хоста, только на чтение; /root закрыт для node — агент её не видит
host=/root/host-home
home=/home/node
# процессы node — без прав root: ограничивающий набор пуст, повышение прав запрещено — правила сети, поставленные claude-box-firewall, им не снять и через setuid-программы
as_node="setpriv --reuid=node --regid=node --init-groups --bounding-set -all --no-new-privs env HOME=$home USER=node"

# домашняя папка контейнера — ~/.claude-box хоста; при первом запуске Compose создаёт её от root
chown node:node "$home"

# перенос пути из домашней папки хоста: есть на хосте — свежая копия, нет — копия прошлого запуска убирается
take() {
  rm -rf "$home/$1"
  [ -e "$host/$1" ] || return 0
  $as_node mkdir -p "$(dirname "$home/$1")"
  cp -r "$host/$1" "$home/$1"
  chown -R node:node "$home/$1"
}

# установка при первом старте: лаунчер ложится в ~/.local/bin, в volume домашней папки; дальше Claude Code обновляется сам
[ -x "$home/.local/bin/claude" ] || $as_node sh -c 'curl -fsSL https://claude.ai/install.sh | bash'

$as_node mkdir -p "$home/.claude"
take .claude/CLAUDE.md
take .claude/hooks
take .gitconfig

# скиллы образа: свежая копия при каждом старте, скиллы пользователя под другими именами рядом остаются.
# Имена box-* принадлежат обвязке: копии прошлого образа уходят целиком — личный скилл берёт верх над одноимённым скиллом проекта,
# и копия /box-task или /box-review из образа до их переезда в проект заслонила бы свежую проектную.
$as_node mkdir -p "$home/.claude/skills"
rm -rf "$home/.claude/skills"/box-*
cp -r /etc/claude-box/skills/* "$home/.claude/skills/"
chown -R node:node "$home/.claude/skills"

hs=$host/.claude/settings.json
[ -r "$hs" ] || hs=/dev/null

# строка состояния — команда из хостовых настроек: пути внутри хостовой ~/.claude переводятся в контейнерную, файлы по ним копируются
statusline=$(jq -r '.statusLine.command // empty' "$hs" | sed "s#[^ \"']*/\.claude/#$home/.claude/#g")
for f in $(printf '%s' "$statusline" | grep -o "$home/\.claude/[^ \"']*" || true); do
  take "${f#$home/}"
done

# настройки сессии: регистрация хука context-guard из образа — при наличии скрипта хука; язык, модель, effort, приписка коммитов и строка состояния — с хоста
[ -f "$home/.claude/hooks/context-guard.sh" ] && hook=true || hook=false
jq -n --argjson hook "$hook" --arg sl "$statusline" \
  --slurpfile base /etc/claude-box/settings.json --slurpfile hs "$hs" '
  ($hs[0] // {}) as $h
  | (if $hook then $base[0] else {} end)
  * ($h | {language, model, effortLevel, modelSettings, attribution, includeCoAuthoredBy} | with_entries(select(.value != null)))
  * (if $sl != "" then {statusLine: ($h.statusLine + {command: $sl})} else {} end)' > "$home/.claude/settings.json"
chown node:node "$home/.claude/settings.json"

# конфиг agent-box — config.yml клона: порог раздела документации для /box-init и протокола, свежая копия в /etc/claude-box/config.yml, агенту только на чтение.
# Клон — цель ссылки ~/.local/bin/agent-loop.sh хоста, путь хоста: от него отрезаются ведущие части, пока остаток не найдётся в домашней папке хоста.
# Клон вне домашней папки хоста или ссылки нет — копии нет, сессии берут порог по умолчанию
conf=/etc/claude-box/config.yml
rm -f "$conf"
rest=$(readlink "$host/.local/bin/agent-loop.sh" || true)
while [ "$rest" != "${rest#*/}" ]; do
  rest=${rest#*/}
  [ -f "$host/$rest" ] || continue
  [ ! -f "$host/${rest%/*}/config.yml" ] || cp "$host/${rest%/*}/config.yml" "$conf"
  break
done

# переменные .env проекта получают только Claude Code и команды агента: файл читается уже от node, часть скрипта от root работает без них
exec $as_node claude-box-env .env claude "$@"
