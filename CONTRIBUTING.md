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

To get the app as a bundle, signed ad hoc for your own Mac:

```sh
scripts/bundle.sh --ad-hoc
codesign --verify --strict --deep build/coreslot.app
```

`scripts/bundle.sh` builds the release executable for Apple silicon and assembles
`build/coreslot.app`: the executable, `Resources/Info.plist` with the version keys, and an icon
drawn from the menu bar glyph. It signs the bundle with the hardened runtime and verifies the
signature. `--version X.Y.Z` sets `CFBundleShortVersionString` and `CFBundleVersion` (0.0.0 by
default); a pre-release suffix such as `-rc1` is left out of both, since Apple requires integers
there. Launch at login is offered only once the app runs from `/Applications`.

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

A debug build of the app takes the flags below; release builds have none of them.
The fixtures are found from the executable up to `Package.swift`, or named with
`--fixtures-dir DIR`.

- `--fixture NAME` runs the whole app, menu bar icon included, over one variant below, with the
  clock starting at the fixture's newest moment.
- `--present NAME[,NAME…]|all [--appearance light|dark]` opens the popover's content over each
  variant in an ordinary window, at the fixture's newest moment, with every row's hover actions
  shown, and prints one line per window, `present-window <kind> <name> <window number>`, then
  `present-ready`. Capture a window with `screencapture -x -o -l <window number> out.png`.
- `timeline[-15m|-1h|-6h|-24h][:NAME][@SECONDS]` as a `--present` name opens the timeline window
  over variant `NAME` (the queue by default) at that range (15 minutes by default), scrolled back
  by `SECONDS` when given: `timeline-6h:night@1800`.

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
cannot read, `unchecked`; two hours of made-up record before the queue's moment, with waits and
their reasons, a watchdog stop and its restart, a run past its timeout, a silence and a failed
reading, `night`, written under the temporary directory, and the same with the record looking off,
`record-off-night`; and `icons`, every state of the menu bar icon. `alert-stop`,
`alert-cancel` and `alert-refused` show the stop confirmation (with a command line holding hidden
characters), the cancel confirmation and the refusal over the queue; an alert draws only while it
runs, so name one per launch, and `all` leaves them out. `settings` shows Settings over the queue
with launch at login as that copy of the app finds it, which outside `/Applications` is "not
offered"; `settings-on`, `settings-approval` and `settings-off` show the service's status as
enabled, waiting for approval and not registered, and change nothing. `all` adds the timeline at
each range over the queue and over `night`, and over `record-off` and `record-off-night`, and the
four Settings variants.

Two more debug flags drive a stop through the app's own path against a real `coreslot`, without a
click: `--answer yes|no` answers every confirmation unseen and prints its text to stderr, and
`--ask-stop LABEL` asks once to stop the first stoppable hold of that label. Use them only with
`CORESLOT_STATE_DIR` set to a throwaway directory, for both the `coreslot run` and the app.

`--measure PHASE:SECONDS[,PHASE:SECONDS…]` runs the live app through phases and quits: `closed`
opens nothing, `popover` opens the popover's content and `timeline` the timeline window at 24 h, each
in an ordinary window above the others, in place of a person who opened it. At each phase's end it
prints to stderr the CPU time of the app and of the `coreslot` runs it reaped, from `getrusage`, as
a share of one core; read the memory with `footprint -p <pid>` meanwhile. To measure the optimised
code with this flag, build `swift build -c release -Xswiftc -DDEBUG --build-path <elsewhere>`; the
release build itself has no debug flag. For example, with a few `coreslot run`s holding and waiting
in the same throwaway `CORESLOT_STATE_DIR`:

```sh
coreslot-menubar --measure closed:600,popover:300,timeline:300
```

## Releasing

Releases are signed with the owner's Developer ID and notarised by Apple on the release Mac, not in
CI. That Mac holds a signing keychain, `~/Library/Keychains/coreslot-signing.keychain-db`, with the
Developer ID Application identity and the notary profile `coreslot-notary`; every `codesign` and
`notarytool` call names that keychain. It has no lock timeout, and the owner unlocks it once after
each reboot:

```sh
security unlock-keychain ~/Library/Keychains/coreslot-signing.keychain-db
```

Then, from a clean checkout with the release tag at `HEAD`:

```sh
git tag -a v0.1.0 -m "coreslot-menubar 0.1.0"
scripts/release.sh 0.1.0
```

`scripts/release.sh` refuses a dirty tree, or a version whose tag `vVERSION` is not at `HEAD`. It
runs `scripts/bundle.sh` with the Developer ID identity, zips the app, submits the zip to the notary
service and waits, staples the ticket to the app, checks the app with `spctl --assess`, zips it
again as `build/coreslot-menubar-VERSION.zip`, and prints the zip's sha256 for the cask. A locked
keychain stops it before anything is signed, with one sentence asking for the unlock above. It
pushes nothing and publishes nothing: pushing the tag, the GitHub release with the zip and the
cask's new `version` and `sha256` in
[core-slot/homebrew-tap](https://github.com/core-slot/homebrew-tap) are separate steps.
