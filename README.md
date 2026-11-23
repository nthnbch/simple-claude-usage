# Simple Claude Usage

A tiny macOS menu bar app that shows your Claude subscription usage: plan, 5-hour session %, and weekly %.

## Why

I wanted something simple, safe and personal: no risk, no account to hand over, no need to open the official Claude app just to check how much I have left. One glance at the menu bar, that's all.

Languages: English, Français, Deutsch, Italiano, Русский, Español (follows the system language).

- Hover or click the menu bar icon to see details. The menu bar shows the 5h percentage.
- One Swift file (~170 lines), no dependencies, no Dock icon.
- Refreshes every 2 minutes.

## Install

Requires macOS 13+, Xcode command line tools, and **Claude Code (the CLI) logged in once**. The Claude Desktop app is *not* required: this app only reads the credentials Claude Code stores in your keychain.

```sh
git clone https://github.com/nthnbch/simple-claude-usage.git
cd simple-claude-usage
./build.sh
open build/ClaudeUsage.app
```

To keep it permanently, move it to `/Applications` and add it to Login Items.

## Safety

- Reads the OAuth token from Claude Code's existing keychain item (macOS asks permission once; choose "Always Allow").
- The token is only sent to `api.anthropic.com`. It is never stored, logged, or refreshed by this app. The token lasts a few hours and is renewed by Claude Code itself when you use it; if it has expired, the app tells you and resumes as soon as Claude Code has renewed it. (Refreshing it ourselves could invalidate your Claude Code login, so we deliberately don't.)
- Uses an undocumented Anthropic endpoint (`/api/oauth/usage`), which may change.

## License

MIT
