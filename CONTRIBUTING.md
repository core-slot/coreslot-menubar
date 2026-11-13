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
