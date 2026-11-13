# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- The app's own log in the macOS unified log, subsystem `io.github.core-slot.menubar`: changes in
  what coreslot reports, the coreslot found, each cancel and stop and its outcome, errors reading
  the record, and the choices made in Settings. The README's Diagnostics section has the command
  that reads it.
- Stop and Withdraw without a pointer: a row that offers one also has it as its accessibility
  action and as an item in its context menu.
- `SECURITY.md`: how to report a vulnerability, and what the stop control checks and does not
  defend against.
- README sections on verifying the download and on uninstalling.

### Fixed

- Polling: a coreslot missing at one poll no longer leaves a second poller running for the life of
  the app, and a coreslot replaced or overwritten in place has its version read again.
- A coreslot whose version line lists several protocol formats no longer reads as not found.
- The timeline says "past its usual time" and "no estimate" as the popover does, draws no start
  for an expected wait of 0, draws a run that went ahead when its wait timed out (`--on-timeout run`)
  as running from then, and leaves out pass-through runs.
- The release build carries no debug map, local build path or debug hook, and the release script
  refuses one that does.

## v0.1.0 (2026-11-13)

The first release: a menu bar view of one machine's coreslot, for macOS 26 or later on Apple silicon,
with coreslot 0.8.0 or later.

### Added

- The menu bar item, in one slot: a glyph that shows whether coreslot is idle, running, queueing,
  short of memory or unavailable.
- The popover:
  - running commands with their memory and expected finish;
  - waiting requests in queue order, with why each waits and when the first is expected to start;
  - the machine's memory split into coreslot's commands, their set-aside growth, everything outside
    coreslot, free memory and coreslot's reserve.
- Withdrawing a waiting request, and stopping a running command, each after a confirmation. The stop
  check is anchored in the process's own executable and start time, and the confirmation shows its
  real command line.
- A timeline window of the last minutes to hours: memory, runs and waits from coreslot's telemetry.
- Settings: the coreslot binary, a state directory for development, and launch at login.
- A signed, notarised and stapled build, installed as the `coreslot-menubar` cask from
  `core-slot/tap`.
