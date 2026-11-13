# coreslot-menubar

A macOS menu bar app for [coreslot](https://github.com/core-slot/coreslot).

coreslot has no daemon and no window of its own. This app watches one machine's coreslot from the
menu bar and shows:

- what runs now, how much memory each command holds, and when it is expected to finish;
- what waits, in queue order, why each one waits, and when the first in line is expected to start;
- where the machine's memory is: coreslot's commands, what coreslot has set aside for their growth,
  everything outside coreslot, what is free, and the reserve coreslot keeps back;
- the last minutes to hours as a timeline.

It can also withdraw a waiting request and stop a running command, each after a confirmation.

The app is a reader. It never writes into coreslot's state directory, opens no network connection,
and runs no program but the `coreslot` binary it found. Every number it shows is one coreslot
reports, or is marked as a forecast.

## Requirements

- macOS 26 or later, on Apple silicon.
- coreslot 0.8.0 or later. With an older coreslot the app says so and shows what that release's
  `status --json` gives.

The app finds `coreslot` in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and then on its
own `PATH`. In Settings it can be pointed at another binary, and, for development, at another state
directory, which it passes to coreslot as `CORESLOT_STATE_DIR`. Launch at login is a setting, off
by default, offered once the app runs from `/Applications`.

## Install

From the Homebrew tap, coreslot first and then the app, which is signed with a Developer ID and
notarised by Apple:

```sh
brew install core-slot/tap/coreslot
brew install --cask core-slot/tap/coreslot-menubar
```

The cask does not install coreslot, so an existing coreslot (for example in `~/.local/bin`) is the
one the app uses. To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Verify the download

The release's sha256 is shown beside `coreslot-menubar-VERSION.zip` on its release page, and the
cask carries the same value, which Homebrew checks when it installs. For a zip downloaded by hand,
compare it with:

```sh
shasum -a 256 coreslot-menubar-VERSION.zip
```

Once the app is in `/Applications`, check that macOS accepts it as notarised:

```sh
spctl -a -vv /Applications/coreslot.app
```

It should say `accepted` and `source=Notarized Developer ID`.

## Uninstall

```sh
brew uninstall --cask coreslot-menubar
```

This quits the app and removes it. With `--zap` (`brew uninstall --zap --cask coreslot-menubar`)
its preferences and saved window state go too. If launch at login was on, its entry may stay in
System Settings → General → Login Items; remove it there. coreslot itself stays installed.

## Diagnostics

The app keeps its own log in the macOS unified log, which the system bounds and keeps; it writes
no file of its own. When the app showed or did something unexpected, read the last day with:

```sh
log show --predicate 'subsystem == "io.github.core-slot.menubar"' --last 1d --style compact
```

It logs changes, never every poll, in four categories:

- `status`: the coreslot found, changed or lost, with its path, and its version when found; each
  change in what `coreslot status --json` gave: a document, notices only, or a problem in the
  popover's words, which give the exit status or system error of a failed `status` (a state error,
  exit 3, gives none); and each notice as it appears and as it clears (degraded and its reason,
  format not understood, config error, an older coreslot, another schema).
- `actions`: each cancel asked, not asked (no coreslot, or another action in flight), declined,
  requested, refused (with what `status` then gave) or failed, with the ticket. Each stop asked,
  not asked, declined, not sent and why, or `SIGTERM` sent or failed with its errno, with a pid and
  a start time from one read, the check that ended the stop or the read right before the signal (the
  row's pid and `unknown` when none read the process), and the hold.
- `telemetry`: an error reading the telemetry or the run log, by stream (`samples`, `events`,
  `runs`) and errno, once while it lasts and once when it ends; choosing another coreslot or state
  directory starts afresh, so an error that outlasts the change is logged again.
- `settings`: the coreslot and the state directory chosen, by path, and launch at login turned on
  or off, with the status the system then reports and its error, if any.

Failures are logged as errors, everything else as notices. A process's arguments are never logged.
Text from the state directory, such as hold and ticket names (which carry part of a label) and
reasons, is logged with its control and invisible characters escaped, after the app's own facts, so
the system's cut of a long line takes the name, not the facts. For coreslot's own side, run
`coreslot doctor`.

## License

MIT, see [LICENSE](LICENSE).
