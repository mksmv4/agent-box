# Образ claude-box: Claude Code в терминале контейнера, образец проекта и скиллы обвязки.
# Сам Claude Code ставится при первом старте в volume домашней папки.
# Сборка — из корня репозитория agent-box: docker compose build claude
FROM node:20

# jq — сборка настроек при старте и хук context-guard; python3-venv — чтение .env проекта при старте, виртуальные окружения и pip для Python-проектов;
# iptables — ограничение сети итераций движка
RUN apt-get update && apt-get install -y --no-install-recommends jq python3-venv iptables \
 && rm -rf /var/lib/apt/lists/*

COPY container/settings.json /etc/claude-box/settings.json
COPY container/entrypoint.sh /usr/local/bin/claude-box
COPY container/env-run.py /usr/local/bin/claude-box-env
COPY container/firewall.sh /usr/local/bin/claude-box-firewall
# образец проекта для /box-init; скиллы скрипт запуска кладёт в ~/.claude/skills
COPY template/ /etc/claude-box/template/
COPY skills/ /etc/claude-box/skills/

ENV PATH=/home/node/.local/bin:$PATH
WORKDIR /workspace
# старт от root: скрипт запуска переносит файлы хоста и запускает Claude Code от node
ENTRYPOINT ["claude-box"]
