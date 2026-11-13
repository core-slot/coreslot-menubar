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

## Diagnostics

The app keeps its own log in the macOS unified log, which the system bounds and keeps; it writes
no file of its own. When the app showed or did something unexpected, read the last day with:

```sh
log show --predicate 'subsystem == "io.github.core-slot.menubar"' --last 1d --style compact
```

It logs changes, never every poll, in four categories:

- `status`: the coreslot found, a new one or none, with its path and version; each change in what
  `coreslot status --json` gave (a document, notices only, or a problem with its exit code); and
  each notice as it appears and clears (degraded and its reason, format not understood, config
  error, an older coreslot, another schema).
- `actions`: each cancel and stop asked, declined or sent, with the ticket or the hold, its pid and
  start time, each refusal and its reason, the signal sent and the result or errno.
- `telemetry`: an error reading the telemetry or the run log, once while it lasts and once when it
  ends.
- `settings`: the coreslot and the state directory chosen, and launch at login asked, with the
  status the system then reports.

Failures are logged as errors, everything else as notices. A process's arguments are never logged;
text from the state directory, such as names and reasons, is logged with its control and invisible
characters escaped. For coreslot's own side, run `coreslot doctor`.

## License

MIT, see [LICENSE](LICENSE).
