# codex-window-keeper

A Codex 5-hour usage window only starts when you send a request. This systemd timer checks when your current window has ended and, as soon as it has, sends one tiny ephemeral message (`Hi`) to `gpt-6-luna` at low effort, so the next window starts right away.

## How it works

Every 15 minutes it reads your 5-hour window from ChatGPT's usage endpoint (the data behind Codex's usage display), using the login in `~/.codex/auth.json`. It talks to OpenAI directly, with no proxy.

- Window in use: waits for its real reset time, then pings once.
- Window idle (0% used; OpenAI reports a rolling "now + 5h" reset): pings, then keeps its own 5-hour cadence from the last ping.
- Usage endpoint unavailable: falls back to 5 h after the last successful ping.

At most one ping per window, guarded by a lock and a state file.

## Requirements

- Linux with systemd
- [Codex CLI](https://github.com/openai/codex) logged in with ChatGPT (`codex login`)
- `curl`, `jq`

## Install (no git needed)

```bash
curl -fsSL https://github.com/rdna897/Codex-window-keeper/archive/refs/heads/main.tar.gz | tar -xz -C /tmp \
  && sudo /tmp/Codex-window-keeper-main/install.sh
```

Run as the user who is logged in to Codex. The installer sets up the job for that user (override with `KEEPER_USER=name`), enables the timer so it survives reboots, and ends with a dry run showing the current decision. Re-running it keeps your settings. If you're already root, drop `sudo`.

## Usage

```bash
codex-window-keeper.sh --dry-run               # show the decision, send nothing
journalctl -u codex-window-keeper -n 20        # logs
systemctl list-timers codex-window-keeper.timer
```

Settings (model, effort, prompt) are in `/etc/default/codex-window-keeper`. Set `LIVE_TRIGGER_ENABLED=0` to disarm.

## Uninstall

```bash
sudo /tmp/Codex-window-keeper-main/install.sh uninstall
```

## Caveat

The usage endpoint (`chatgpt.com/backend-api/wham/usage`) is undocumented and may change.
