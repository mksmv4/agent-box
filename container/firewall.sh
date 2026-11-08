#!/bin/bash
# Ограничение сети контейнера для итераций движка автоцикла: исходящие — только на разрешённые адреса, затем обычный скрипт запуска claude-box.
# Вызов — точкой входа: docker compose -f claude-box.yml run --rm --entrypoint claude-box-firewall claude [флаги claude]; так итерации запускает agent-loop.sh.
# Нужны права NET_ADMIN и NET_RAW сервиса claude — строка cap_add в claude-box.yml проекта.
set -euo pipefail

say() { printf 'claude-box-firewall: %s\n' "$*" >&2; }

err=$(iptables -S 2>&1 >/dev/null) || {
  say "правила сети не ставятся: $err"
  say "сервису claude в claude-box.yml проекта нужна строка cap_add: [NET_ADMIN, NET_RAW]"
  exit 1
}

# адреса домена в список: адреса — на момент старта, домен, сменивший адрес за время сессии, получает отказ
resolve() {
  local -n to=$1
  local ips
  ips=$(getent ahostsv4 "$2" | awk '{print $1}' | sort -u) || true
  [ -n "$ips" ] || { say "адрес $2 не найден"; exit 1; }
  to+=($ips)
}

# Claude Code — модель, вход и токены, установка и обновление, документация; npm и PyPI; GitHub — диапазоны сайта, API и git
web=()
for d in api.anthropic.com claude.ai platform.claude.com downloads.claude.ai code.claude.com \
  registry.npmjs.org pypi.org files.pythonhosted.org; do
  resolve web "$d"
done
# диапазоны GitHub — у самого GitHub: сбой его API закрывает GitHub до конца сессии, сеть остального списка работает
if gh=$(curl -fsS --max-time 15 https://api.github.com/meta | jq -r '(.web + .api + .git)[] | select(contains(":") | not)'); then
  web+=($gh)
else
  say "предупреждение: диапазоны GitHub не получены — GitHub закрыт до конца сессии"
fi
mapfile -t web < <(printf '%s\n' "${web[@]}" | sort -u)

# свои адреса проекта — CLAUDE_BOX_ALLOW в environment: сервиса claude: домены, адреса IPv4 и подсети через пробел или запятую, все порты
own=()
IFS=', ' read -ra items <<<"${CLAUDE_BOX_ALLOW:-}"
for a in "${items[@]}"; do
  case $a in
    *[!0-9./]*) resolve own "$a" ;;
    *) own+=("$a") ;;
  esac
done

# сети контейнера — сервисы проекта и сам компьютер по адресу шлюза: маршруты без шлюза, адреса в /proc/net/route — шестнадцатеричные, байты в обратном порядке
hex() { printf '%d.%d.%d.%d' "0x${1:6:2}" "0x${1:4:2}" "0x${1:2:2}" "0x${1:0:2}"; }
nets=()
while read -r _ dest gw _ _ _ _ mask _; do
  if [ "$gw" = 00000000 ] && [ "$dest" != 00000000 ]; then
    nets+=("$(hex "$dest")/$(hex "$mask")")
  fi
done < <(tail -n +2 /proc/net/route)

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
for n in "${nets[@]}"; do
  iptables -A INPUT -s "$n" -j ACCEPT
  iptables -A OUTPUT -d "$n" -j ACCEPT
done
for a in "${own[@]}"; do
  iptables -A OUTPUT -d "$a" -j ACCEPT
done
# общие адреса — только HTTP и HTTPS: SSH и прочие порты закрыты
for a in "${web[@]}"; do
  iptables -A OUTPUT -d "$a" -p tcp -m multiport --dports 80,443 -j ACCEPT
done
# прочие исходящие — отказ сразу, без ожидания таймаута
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# IPv6 — только localhost
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -j REJECT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# самопроверка: закрытый сайт отклонён, модель доступна — иначе Claude Code не запускается
if curl -s -o /dev/null --max-time 5 https://example.com; then
  say "проверка не прошла: example.com открыт"
  exit 1
fi
curl -s -o /dev/null --max-time 10 https://api.anthropic.com || { say "проверка не прошла: api.anthropic.com закрыт"; exit 1; }
say "сеть ограничена: открыто адресов ${#web[@]}, своих адресов проекта ${#own[@]}, сети контейнера ${nets[*]:-нет}"

# подключения аккаунта claude.ai идут через mcp-proxy.anthropic.com — у него адрес модели: их закрывает настройка Claude Code
export ENABLE_CLAUDEAI_MCP_SERVERS=false
exec claude-box "$@"
