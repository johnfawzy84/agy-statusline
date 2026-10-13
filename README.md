# agy-statusline

Status line for the **Antigravity CLI** (`agy`) — displays the active model, session context usage, working directory/git branch, and real-time quota consumption.

## What it shows

### Multi-line HUD mode (`STATUSLINE_MODE=multiline`, default)

```
Claude Sonnet 4.6 (Thinking) │ ✍️  27% │ my-project (main*) │ Google AI Pro

claude 5h     ●●○○○○○○○○  21% ⟳ 20:40
claude daily  ○○○○○○○○○○   4% (0.2M / 3.5M) ⟳ 00:00
claude weekly ●○○○○○○○○○  16% (4.0M / 25M) ⟳ jul 4, 20:57
```

### Inline Single-line mode (`STATUSLINE_MODE=inline`)

```
Gemini 3.8 Flash (High) │ ✍️  6% │ ☀️  0.2M/3.5M (5%) │ 📅 0.2M/25M (1%) │ my-project (main*) │ gcp-ge-plus-tier
```

| Field | Description |
|-------|-------------|
| Model | Active model for the current session |
| `✍️ %` | Context window usage for the current session |
| `☀️ daily` | Daily token usage tracked against the ~3.5M tokens/day limit |
| `📅 weekly` | Weekly token usage tracked against the ~25M tokens/week limit |
| `5h` | 5-hour rolling quota (when available on consumer tiers) |
| Directory (branch*) | Working directory + git branch (`*` = uncommitted changes) |
| Plan | Account tier (`Google AI Pro`, `gcp-ge-plus-tier`, etc.) |

> **Enterprise & Pay-As-You-Go tiers (`gcp-ge-plus-tier`):** Google Cloud enterprise accounts do not have consumer rate-limit quotas from the server. `agy-statusline` automatically tracks your active conversation token consumption locally against the 3.5M/day and 25M/week benchmarks.
>
> The quota pool (`claude` or `gemini`) is automatically detected based on the active model — no configuration needed.

## Display Modes

You can switch between **multi-line HUD** and **compact single-line inline** mode at any time.

To set your preference persistently, create or edit `~/.gemini/statusline.env`:

```bash
# Switch to compact single-line mode:
echo 'STATUSLINE_MODE=inline' > ~/.gemini/statusline.env

# Switch back to multi-line HUD mode:
echo 'STATUSLINE_MODE=multiline' > ~/.gemini/statusline.env
```

Alternatively, you can export `STATUSLINE_MODE` in your `~/.bashrc` or `~/.zshrc`.

## Requirements

- [`jq`](https://jqlang.github.io/jq/) — for JSON parsing
- `git` — for branch info
- `agy` (Antigravity CLI) installed and configured

## Installation

```bash
git clone https://github.com/your-username/agy-statusline
cd agy-statusline
bash bin/install.sh
```

Restart `agy` to see the status line.

## Uninstall

```bash
bash bin/uninstall.sh
```

This restores your previous statusline (if any) and removes the `statusLine` entry from `settings.json`.

## Project structure

```
agy-statusline/
├── bin/
│   ├── statusline.sh   # Main script (copied to ~/.gemini/)
│   ├── install.sh      # Installer
│   └── uninstall.sh    # Uninstaller
└── README.md
```

## How it works

`agy` runs the command configured under `statusLine` in `settings.json`, passing the current session state as JSON via stdin. The script parses it and returns ANSI-colored text for the terminal.

The installer configures the following in `~/.gemini/antigravity-cli/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash \"$HOME/.gemini/statusline.sh\"",
  "enabled": true
}
```

You can also toggle the status line at any time from within `agy` using `/statusline`.
