# Security policy

## Reporting a vulnerability

Report it privately, through GitHub: on this repository's **Security** tab, choose **Report a
vulnerability** (GitHub's private vulnerability reporting). Please do not open a public issue for
it. Include the app's version (Get Info on `coreslot.app`), coreslot's (`coreslot version`), the
macOS version, and the smallest sequence of steps that shows the problem.

Only the latest release is supported. A problem in coreslot itself belongs to
[coreslot's security policy](https://github.com/core-slot/coreslot/blob/main/SECURITY.md), whose
threat model this app shares: cooperative admission control for one user on one host, with every
process of that user trusted.

## Scope

The app reads. It runs no program but the `coreslot` it found, opens no network connection and
never writes into coreslot's state directory. It finds `coreslot` in `~/.local/bin` first, with no
signature check: whoever can write there already decides what the user's shell runs.

Its two actions are withdrawing a waiting request, through `coreslot cancel`, and stopping a
running command with a `SIGTERM`, each after a confirmation.

## The stop control

The adversary is a process that can write the state directory but may not signal other
processes, and forges a live hold. Before a `SIGTERM` the app reads `status` again and checks that:

- the hold is live and coreslot marks it stoppable;
- its pid names one process: from 2 up, never 0, -1 or a process group;
- the process at that pid runs the very `coreslot` file the app uses, by the device and inode of
  its mapped executable as the kernel reports them;
- the process started no later than its hold's admission plus 2 s;
- the person has seen the process's own command line, as the kernel reports it, and confirmed.

The checks run again after the confirmation and once more right before the signal; nothing is sent
unless they read the same process.

What it does not defend: a writer of the state directory can still aim a stop at another run of
the same `coreslot`, one coreslot itself would not stop included. The confirmation then shows that
run's real command line, and the person decides.
