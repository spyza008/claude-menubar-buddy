---
name: install-claude-menubar-buddy
description: Build and install Claude Menu Bar Buddy — a hardware-free, native macOS menu bar app that shows a panda that reacts to Claude Code permission requests (Allow/Deny), session status, token usage today, and 5-hour/weekly plan limits. Self-installing — no code signing, no download, compiles fresh on the user's own machine from source in this folder.
---

# Claude Menu Bar Buddy — Self-Install Skill

You are setting this up for **whoever is running you right now** — use *their*
home directory, *their* username, *their* paths. Nothing here should be
hardcoded to any other machine. This folder (containing this SKILL.md,
`Package.swift`, `Sources/`, `generate_gifs.py`, `hook.sh`) is the complete,
portable source — copy the whole folder to the target machine first if it
isn't already there.

**What this gives the user:** a 🐼 icon in their menu bar. When Claude Code
needs a Bash/Write/Edit/WebFetch/NotebookEdit permission decision, it shows
up there (with sound) instead of only in the terminal/Claude Desktop — click
Allow or Deny. The menu also shows session status, tokens used today, and
plan usage (5-hour + weekly limits), refreshed each time it's opened.

## Prerequisites check

1. `swift --version` — needs Swift 5.9+. Ships with Xcode Command Line Tools
   (`xcode-select --install` if missing — Xcode itself is NOT required, CLT
   is enough).
2. `python3 -c "import PIL"` — needed once, to render the panda GIFs from
   pixel-art data. If missing: `pip3 install Pillow`.
3. `jq --version` — used by the hook script to parse tool-call JSON. Install
   via `brew install jq` if missing.

If any prerequisite can't be installed, stop and tell the user what's
missing rather than guessing around it.

## Steps

### 1. Generate the panda GIFs (once)

```bash
cd <this-folder>
python3 generate_gifs.py
```

Confirm `Sources/ClaudeMenuBarBuddy/Resources/buddy_idle.gif` and
`buddy_pending.gif` now exist.

### 2. Build

```bash
cd <this-folder>
swift build
```

Confirm `Build complete!` and that
`.build/debug/ClaudeMenuBarBuddy` exists and runs (`file .build/debug/ClaudeMenuBarBuddy`).

### 3. Install the hook script

`hook.sh` in this folder is already portable (it uses `$HOME`, not a
hardcoded path). Copy it to the user's own config location:

```bash
mkdir -p ~/.config/claude-menubar-buddy
cp hook.sh ~/.config/claude-menubar-buddy/hook.sh
chmod +x ~/.config/claude-menubar-buddy/hook.sh
```

### 4. Wire the hook into Claude Code's settings

Read `~/.claude/settings.json` first (create `{}` if it doesn't exist yet).
**Merge, don't overwrite** — this user may already have other permissions or
hooks configured. Add these `PreToolUse` entries (adjust if a `hooks` key
already exists — append to it, don't replace):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "ABSOLUTE_HOME/.config/claude-menubar-buddy/hook.sh", "timeout": 60, "statusMessage": "Waiting for Claude Menu Bar Buddy..." }] },
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "ABSOLUTE_HOME/.config/claude-menubar-buddy/hook.sh", "timeout": 60, "statusMessage": "Waiting for Claude Menu Bar Buddy..." }] },
      { "matcher": "Edit", "hooks": [{ "type": "command", "command": "ABSOLUTE_HOME/.config/claude-menubar-buddy/hook.sh", "timeout": 60, "statusMessage": "Waiting for Claude Menu Bar Buddy..." }] },
      { "matcher": "WebFetch", "hooks": [{ "type": "command", "command": "ABSOLUTE_HOME/.config/claude-menubar-buddy/hook.sh", "timeout": 60, "statusMessage": "Waiting for Claude Menu Bar Buddy..." }] },
      { "matcher": "NotebookEdit", "hooks": [{ "type": "command", "command": "ABSOLUTE_HOME/.config/claude-menubar-buddy/hook.sh", "timeout": 60, "statusMessage": "Waiting for Claude Menu Bar Buddy..." }] }
    ]
  }
}
```

Replace `ABSOLUTE_HOME` with this user's actual resolved home directory
(e.g. from `echo $HOME`) — **do not use a literal `~`** in the `command`
field; write out the real absolute path. This was verified working this way
during development; don't assume `~` expansion without re-testing it.

Validate after writing:
```bash
python3 -c "import json; json.load(open('$HOME/.claude/settings.json'))" && echo "valid JSON"
```

**Editing settings.json itself will trigger the user's own native Claude Code
permission prompt (this is intentional — settings.json changes are protected
from being self-approved by hooks). Tell the user to expect and approve this
one prompt.**

### 5. Auto-start at login (LaunchAgent)

Write to `~/Library/LaunchAgents/com.claudemenubarbuddy.app.plist`, with
`<string>` paths built from `$HOME` for **this** user (don't hardcode):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudemenubarbuddy.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>REPLACE_WITH_ABSOLUTE_PATH_TO/.build/debug/ClaudeMenuBarBuddy</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/menubar_buddy.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/menubar_buddy.log</string>
</dict>
</plist>
```

`ProgramArguments` **must** be an absolute path (LaunchAgents don't expand
`~`) — resolve `<this-folder>/.build/debug/ClaudeMenuBarBuddy` to an
absolute path for this specific install location before writing.

```bash
plutil -lint ~/Library/LaunchAgents/com.claudemenubarbuddy.app.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claudemenubarbuddy.app.plist
```

### 6. Verify

```bash
ps aux | grep ClaudeMenuBarBuddy | grep -v grep
```

Tell the user to look for the 🐼 in their menu bar. It should show idle
status when clicked. It stays that way until a permission request comes in.

## Notes for whoever's running this skill

- Everything above is idempotent-ish but not bulletproof against re-runs —
  if `com.claudemenubarbuddy.app` is already loaded, `launchctl bootstrap`
  will error; use `launchctl kickstart -k gui/$(id -u)/com.claudemenubarbuddy.app`
  to restart an existing install instead.
- Don't skip the "merge, don't overwrite" step on settings.json — a naive
  overwrite would silently delete whatever permissions/hooks the user
  already had configured. Read first, merge, write.
- If the user later wants to uninstall: `launchctl bootout gui/$(id -u)/com.claudemenubarbuddy.app`,
  delete the plist, remove the `hooks.PreToolUse` entries pointing at
  `claude-menubar-buddy/hook.sh` from settings.json, delete
  `~/.config/claude-menubar-buddy/`.
