#!/usr/bin/env bash
# Starts the working loop every minute with a systemd user timer on this machine.
# A round with no work makes no call to Claude. The timer runs while the user is logged in.
# To stop it: systemctl --user disable --now minion-army-agent.timer
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
mkdir -p "$units"

cat >"$units/minion-army-agent.service" <<UNIT
[Unit]
Description=minion-army: one round of the working loop

[Service]
Type=oneshot
WorkingDirectory=$engine
# A timer has no login shell, so the unit keeps the tools from the shell that installed it.
Environment=PATH=$PATH
# This private file holds CLAUDE_CODE_OAUTH_TOKEN for unattended runs. It stays outside the repository.
EnvironmentFile=-%h/.config/minion-army/agent.env
ExecStart=$engine/scripts/agent-loop.sh
UNIT

cat >"$units/minion-army-agent.timer" <<UNIT
[Unit]
Description=minion-army: start the working loop every minute

[Timer]
OnBootSec=1min
OnUnitInactiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now minion-army-agent.timer
echo "The working loop now starts every minute. Logs: journalctl --user -u minion-army-agent"
