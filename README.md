# clean-my-mac

A single Bash script that finds junk on macOS and asks before removing any of it.

It reports how much space each category takes, lets you remove all of it, pick items one by one, or skip it, and ends with a summary of what was freed.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amirhosseinNouri/clean-my-mac/main/cleanup.sh)
```

Add `--dry-run` at the end to only see what could be removed, or any other [option](#options).

## Quick start

```bash
git clone https://github.com/amirhosseinNouri/clean-my-mac.git
cd clean-my-mac
chmod +x cleanup.sh

./cleanup.sh --dry-run   # see what could be removed, nothing is deleted
./cleanup.sh             # review and remove interactively
```

Run it as your normal user, not with `sudo`. Use `--system` when you also want system-wide locations scanned; it asks for your password itself.

## Options

| Option | Description |
| --- | --- |
| `-n`, `--dry-run` | Only report what could be removed |
| `-y`, `--yes` | Auto-accept low-risk categories (trash, caches, logs); everything else is still confirmed item by item |
| `-s`, `--system` | Also scan system-wide locations (asks for your password) |
| `-m`, `--min-size MB` | Ignore items smaller than `MB` megabytes (default: 1) |
| `-h`, `--help` | Show help |

## What it looks at

**Low risk** (rebuilt automatically; can be removed in bulk):

- Trash, including Trash on external volumes
- User caches and sandboxed app caches
- Mail attachment downloads
- Logs and crash reports
- Developer caches: Xcode DerivedData and device support files, simulator caches, SwiftUI previews, npm, pnpm, Gradle, Cargo and Android caches
- Docker Desktop and WhatsApp data, only when those apps are no longer installed or running

**Maintenance commands** (shown with their exact command before running):

- `brew cleanup -s --prune=all`
- `xcrun simctl delete unavailable`
- `go clean -modcache`
- `docker system prune -f` (volumes are kept)
- `tmutil thinlocalsnapshots` for local Time Machine snapshots

**Higher risk** (always confirmed one item at a time, default is no):

- Leftover settings and data of apps that are no longer installed
- Launch agents whose program no longer exists
- Xcode archives, `~/.cache`, Maven repository
- "Install macOS" apps
- iOS device backups and firmware files

**With `--system`:**

- `/Library/Caches`, `/Library/Logs`, rotated logs in `/private/var/log` older than a week
- System launch agents and daemons whose program no longer exists

## Safety

- Nothing is removed without confirmation. Without a terminal to ask on, the script falls back to a dry run.
- Removed items are deleted permanently, not moved to the Trash (that would not free any space). Use `--dry-run` first.
- Never touched: `~/Downloads`, Keychains, iCloud Drive, Mail, Messages, Calendars, Contacts, Photos libraries, and Chrome profiles (cookies, logins, history).
- Deletion is restricted to an allowlist of locations (inside `~/Library`, the Trash, known cache folders, and a few system paths). Anything else is refused.
- Leftover detection matches on the app's vendor (e.g. `com.google`), so shared helpers and updaters are not flagged. Folders guessed only by name must also be untouched for 90 days. If the list of installed apps can't be built reliably, the app-data categories are skipped.
- Items changed in the last 30 days are marked in the list.

Quit open apps before running it. Some apps rebuild their caches on first launch, which may make that launch slower.

## Requirements

- macOS (Bash 3.2 that ships with macOS is enough)
- For a complete scan, give your terminal Full Disk Access in **System Settings > Privacy & Security > Full Disk Access**. The script warns you when it's missing.
