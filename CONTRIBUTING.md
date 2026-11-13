# Contributing

Issues and pull requests are welcome; for anything larger than a fix, open an issue first so the
design can be settled before the code. Contributions are taken under the MIT license of the
repository ([LICENSE](LICENSE)).

## Ground rules

- **coreslot's documents are the contract.** The app reads only what coreslot documents:
  [`status --json`](https://github.com/core-slot/coreslot/blob/v0.8.0/docs/status-json.md),
  [the telemetry files](https://github.com/core-slot/coreslot/blob/v0.8.0/docs/telemetry.md) and
  [the run log](https://github.com/core-slot/coreslot/blob/v0.8.0/PROTOCOL.md#20-run-log). It
  applies none of coreslot's rules and writes nothing under the state directory.
- **No third-party dependencies.**
- **Every test that can be broken names the mutation that turns it red**, in a one-line comment.
  Make the mutation, run the test, see it fail for that reason, and revert it.
- English for all prose, comments and messages.

## Build

Xcode 26 or later (Swift 6.2 or later), on macOS 26 or later.

```sh
swift build -c release
```

## Test

```sh
swift test
swift test --filter StatusTests
```

CI runs both on every pull request and on every push to `main`.

## Fixtures

The tests read recorded coreslot states from `Tests/CoreslotKitTests/Fixtures/`. They come from
`scripts/make-fixtures.sh`, which drives a real `coreslot` in a budget of its own: a fresh, empty
state directory, never the one your commands use.

```sh
CORESLOT_STATE_DIR="$(mktemp -d)" scripts/make-fixtures.sh "$(command -v coreslot)"
```

It runs `sleep` commands under the labels `demo:short`, `demo:long` and `demo:wait`, writes one
`status-<name>.json` per state and copies the telemetry and run log beside it, replaces every
process name of the `memory` lines with `proc-1`, `proc-2`, …, and refuses to finish if a fixture
holds another label, your user name or your home directory. Read the diff before committing it.

`status-0.7.0.json` is not from the script: it is a 0.8.0 fixture with the keys 0.8.0 added
removed by hand, so the tests cover an older coreslot.

## Looking at the UI

A debug build of the app takes two flags that read the fixtures above; release builds have neither.
The fixtures are found from the executable up to `Package.swift`, or named with
`--fixtures-dir DIR`.

- `--fixture NAME` runs the whole app, menu bar icon included, over one variant below, with the
  clock starting at the fixture's newest moment.
- `--present NAME[,NAME…]|all [--appearance light|dark]` opens the popover's content over each
  variant in an ordinary window, at the fixture's newest moment, with every row's hover actions
  shown, and prints one line per window, `present-window <kind> <name> <window number>`, then
  `present-ready`. Capture a window with `screencapture -x -o -l <window number> out.png`.

```sh
swift run coreslot-menubar --present all --appearance dark
```

The variants: the fixtures `idle`, `queue`, `cancelled`, `dead`, `stopped`, `no-typical` and
`0.7.0` (an older coreslot); the queue with the watchdog `normal`, `yellow`, `red` and `floor`; the
queue as a document with a notice, `degraded`, `format` (not understood) and `config-error`; a
document of another schema, `schema-2`; no document at all, `not-found`, `state-unreadable` (exit 3,
nothing printed), `exit-64`, `exit-70`, `malformed` and `timeout`; the queue with the local record
looking off, `record-off`; holds reserving more than the machine has, `shortfall`; labels and a
degraded reason with control, bidirectional, zero-width and tag characters and a container hold,
`untrusted`; more rows than the popover shows unscrolled, `many`; holds whose process the app
cannot read, `unchecked`; and `icons`, every state of the menu bar icon. `alert-stop`,
`alert-cancel` and `alert-refused` show the stop confirmation (with a command line holding hidden
characters), the cancel confirmation and the refusal over the queue; an alert draws only while it
runs, so name one per launch, and `all` leaves them out.

Two more debug flags drive a stop through the app's own path against a real `coreslot`, without a
click: `--answer yes|no` answers every confirmation unseen and prints its text to stderr, and
`--ask-stop LABEL` asks once to stop the first stoppable hold of that label. Use them only with
`CORESLOT_STATE_DIR` set to a throwaway directory, for both the `coreslot run` and the app.
