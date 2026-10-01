#!/bin/sh
# Запуск Claude Code в контейнере claude-box; аргументы запуска уходят в claude.
# Старт от root: из домашней папки хоста переносится то, что там есть, затем Claude Code запускается от node.
set -e

# домашняя папка хоста, только на чтение; /root закрыт для node — агент её не видит
host=/root/host-home
home=/home/node
as_node="setpriv --reuid=node --regid=node --init-groups env HOME=$home USER=node"

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

# скиллы образа: свежая копия при каждом старте, скиллы пользователя рядом остаются
$as_node mkdir -p "$home/.claude/skills"
for s in /etc/claude-box/skills/*; do
  rm -rf "$home/.claude/skills/${s##*/}"
  cp -r "$s" "$home/.claude/skills/"
done
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

# вход Claude Code в контейнере — всегда подписка: ключи и переключатели провайдера из .env проекта убираются, программы агента их тоже не видят
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

exec $as_node claude "$@"
