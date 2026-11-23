# Simple Claude Usage

A tiny macOS menu bar app that shows your Claude subscription usage: plan, 5-hour session %, and weekly %.

- Hover or click the menu bar icon to see details. The menu bar shows the 5h percentage.
- One Swift file (~170 lines), no dependencies, no Dock icon.
- Refreshes every 2 minutes.

## Install

Requires macOS 13+, Xcode command line tools, and Claude Code logged in.

```sh
git clone https://github.com/nthnbch/simple-claude-usage.git
cd simple-claude-usage
./build.sh
open build/ClaudeUsage.app
```

To keep it permanently, move it to `/Applications` and add it to Login Items.

## Safety

- Reads the OAuth token from Claude Code's existing keychain item (macOS asks permission once; choose "Always Allow").
- The token is only sent to `api.anthropic.com`. It is never stored, logged, or refreshed by this app. If it expires, open Claude Code.
- Uses an undocumented Anthropic endpoint (`/api/oauth/usage`), which may change.

## License

MIT
