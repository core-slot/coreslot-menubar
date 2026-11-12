#!/bin/bash
# Records the coreslot states the tests read, from a real coreslot in a budget of its own.
#
#   CORESLOT_STATE_DIR="$(mktemp -d)" scripts/make-fixtures.sh "$(command -v coreslot)"
#
# Writes Tests/CoreslotKitTests/Fixtures/status-<name>.json and telemetry-<name>/ (the state
# directory's telemetry/ and log/ as they were at that reading), for each state below. Needs jq
# and python3. Nothing is written into the repository unless every check at the end passes.
set -euo pipefail

die() { echo "make-fixtures: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: CORESLOT_STATE_DIR=<fresh empty directory> $0 COR"
cor=$1
[ -x "$cor" ] || die "$cor is not an executable"
state=${CORESLOT_STATE_DIR:-}
[ -n "$state" ] || die "set CORESLOT_STATE_DIR to a fresh empty directory"
case $state in /*) ;; *) die "CORESLOT_STATE_DIR must be an absolute path" ;; esac
[ -d "$state" ] || die "CORESLOT_STATE_DIR=$state is not a directory"
[ -z "$(ls -A "$state")" ] || die "CORESLOT_STATE_DIR=$state is not empty"
export CORESLOT_STATE_DIR=$state
command -v jq >/dev/null || die "jq is required"
command -v python3 >/dev/null || die "python3 is required"

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/Tests/CoreslotKitTests/Fixtures
stage=$(mktemp -d)
echo "make-fixtures: $("$cor" version)"

# A smaller reserve leaves room for the needs below on a machine that is already busy.
printf '[memory]\nreserve = "256M"\n\n[telemetry]\nenabled = true\n' >"$state/config.toml"
chmod 600 "$state/config.toml"

started=()
cleanup() {
    for p in "${started[@]:-}"; do [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || true; done
    rm -rf "$stage"
}
trap cleanup EXIT

# start ARGS... runs `coreslot run ARGS` in the background and leaves its pid in $last.
start() {
    "$cor" run "$@" >/dev/null 2>&1 &
    last=$!
    started+=("$last")
}

st() {
    local rc=0
    "$cor" status --json || rc=$?
    [ $rc -eq 0 ] || die "status --json exited $rc"
}

# until WHAT JQ waits up to 30 s for JQ, over a status reading, to print true.
until_status() {
    for _ in $(seq 150); do
        [ "$(st | jq -r "$2")" = true ] && return 0
        sleep 0.2
    done
    die "timed out waiting for $1"
}

# until_waiting waits up to 30 s for every ticket of the queue to have a waiting line, joined to
# it through its enqueue line's ticket name and (run, attempt).
until_waiting() {
    local names
    for _ in $(seq 150); do
        names=$(st | jq -c '[.tickets[].name]')
        if [ -f "$state/telemetry/events.jsonl" ] && [ "$(jq -s --argjson names "$names" '
            . as $lines | [$names[] as $n
                | ($lines | map(select(.e == "enqueue" and .ticket == $n)) | last) as $q
                | $q != null and ($lines | any(.e == "waiting" and .run == $q.run and .attempt == $q.attempt))]
            | all' "$state/telemetry/events.jsonl")" = true ]; then
            return 0
        fi
        sleep 0.2
    done
    die "timed out waiting for the waiting lines"
}

# room prints the room a new job may take now, in MiB.
room() { st | jq -r '.mem.room_mib'; }

ticket_id() { st | jq -r --argjson pid "$1" '.tickets[] | select(.pid == $pid) | .id'; }

# finish PID CODE waits for a run started here and checks its exit status.
finish() {
    local rc=0
    wait "$1" || rc=$?
    [ "$rc" -eq "$2" ] || die "run $1 exited $rc, not $2"
}

capture() {
    local dir=$stage/telemetry-$1 f
    st >"$stage/status-$1.json"
    mkdir -p "$dir/telemetry" "$dir/log"
    for f in samples.jsonl samples.1.jsonl events.jsonl events.1.jsonl; do
        [ -f "$state/telemetry/$f" ] && cp "$state/telemetry/$f" "$dir/telemetry/"
    done
    for f in runs.jsonl runs.1.jsonl; do
        [ -f "$state/log/$f" ] && cp "$state/log/$f" "$dir/log/"
    done
    echo "make-fixtures: captured $1"
}

# Two counted runs give demo:short and demo:long a typical run time.
"$cor" run --restart=yes --label demo:short --mem 64M -- sleep 1 >/dev/null 2>&1
"$cor" run --restart=yes --label demo:long --mem 64M -- sleep 8 >/dev/null 2>&1
capture idle

# Two holds, one of them stoppable, and two tickets that do not fit until the large hold ends.
start --restart=no --label demo:short --mem 64M -- sleep 300
short=$last
until_status "the first hold" '.holds | length == 1'
r=$(room)
[ "$r" -ge 1280 ] || die "the machine offers $r MiB of room; these states need 1280"
start --restart=yes --label demo:long --mem "$((r - 256))M" -- sleep 300
long=$last
until_status "the second hold" '.holds | length == 2'
start --restart=yes --label demo:wait --mem 1024M -- sleep 1
wait1=$last
until_status "the first ticket" '.tickets | length == 1'
start --restart=yes --label demo:short --mem 1024M -- sleep 1
wait2=$last
until_status "the second ticket" '.tickets | length == 2'
until_waiting
sleep 2
capture queue
[ "$(jq '(.holds | length) == 2 and ([.tickets[] | select(.state == "waiting")] | length) == 2' \
    "$stage/status-queue.json")" = true ] || die "the queue state is not two holds and two waiting tickets"

# Both tickets withdrawn, both holds ended by SIGTERM.
"$cor" cancel "$(ticket_id "$wait1")" >/dev/null
"$cor" cancel "$(ticket_id "$wait2")" >/dev/null
finish "$wait1" 75
finish "$wait2" 75
kill -TERM "$short" "$long"
finish "$short" 143
finish "$long" 143
until_status "an empty state" '(.holds | length) == 0 and (.tickets | length) == 0'
capture stopped

# A ticket behind a hold whose label has no typical run time, then that ticket cancelled.
r=$(room)
[ "$r" -ge 1280 ] || die "the machine offers $r MiB of room; these states need 1280"
start --restart=yes --label demo:wait --mem "$((r - 256))M" -- sleep 300
hold=$last
until_status "the hold" '.holds | length == 1'
start --restart=yes --label demo:short --mem 1024M -- sleep 1
waiter=$last
until_status "the ticket" '.tickets | length == 1'
until_waiting
sleep 2
capture no-typical
"$cor" cancel "$(ticket_id "$waiter")" >/dev/null
finish "$waiter" 75
until_status "the cancelled ticket gone" '.tickets | length == 0'
capture cancelled

# A ticket whose waiter was killed: its file stays, and status calls it dead.
start --restart=yes --label demo:short --mem 1024M -- sleep 1
waiter=$last
until_status "the ticket" '.tickets | length == 1'
until_waiting
kill -KILL "$waiter"
finish "$waiter" 137
until_status "a dead ticket" '[.tickets[] | select(.state == "dead")] | length == 1'
capture dead
kill -TERM "$hold"
finish "$hold" 143

# Process names become proc-1, proc-2, ...; then nothing may name another label, the user or home.
python3 -I - "$stage" "$(id -un)" "$HOME" <<'PY'
import json, os, sys

stage, user, home = sys.argv[1], sys.argv[2], sys.argv[3]
names = {}

def alias(name):
    return names.setdefault(name, "proc-%d" % (len(names) + 1))

def labels(value, path):
    if isinstance(value, dict):
        for k, v in value.items():
            if k == "label" and not (isinstance(v, str) and v.startswith("demo:")):
                yield path + "." + k, v
            yield from labels(v, path + "." + k)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from labels(v, "%s[%d]" % (path, i))

files = sorted(os.path.join(d, f) for d, _, fs in os.walk(stage) for f in fs)
for path in files:
    if not path.endswith(".jsonl"):
        continue
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            o = json.loads(line)
            if o.get("e") == "memory":
                for p in o.get("top") or []:
                    p["name"] = alias(p["name"])
                if o.get("vm"):
                    o["vm"]["name"] = alias(o["vm"]["name"])
                line = json.dumps(o, separators=(",", ":"), ensure_ascii=False) + "\n"
            out.append(line)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)

bad = []
for path in files:
    rel = os.path.relpath(path, stage)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    docs = [json.loads(text)] if path.endswith(".json") else [json.loads(l) for l in text.splitlines()]
    for i, doc in enumerate(docs):
        bad += ["%s:%d %s is %r" % (rel, i + 1, p, v) for p, v in labels(doc, "")]
    for i, line in enumerate(text.splitlines()):
        for word in (user, home):
            if word and word.lower() in line.lower():
                bad.append("%s:%d carries %r" % (rel, i + 1, word))
if bad:
    sys.exit("make-fixtures: refusing to finish:\n  " + "\n  ".join(bad))
PY

mkdir -p "$out"
find "$out" -maxdepth 1 \( -name 'status-*.json' ! -name 'status-0.7.0.json' -o -name 'telemetry-*' \) \
    -exec rm -rf {} +
cp -R "$stage"/. "$out"/
echo "make-fixtures: wrote $(ls "$stage" | wc -l | tr -d ' ') entries to $out"
