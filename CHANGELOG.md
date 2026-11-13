# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
