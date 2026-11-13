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
own `PATH`, and can be pointed at another binary.

## Install

With the first release, as a Homebrew cask beside the coreslot formula:

```sh
brew install --cask core-slot/tap/coreslot-menubar
```

Until then, build it from source: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT, see [LICENSE](LICENSE).
