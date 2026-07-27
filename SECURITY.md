# Security Policy

## Reporting

Open a GitHub Issue. This is a personal project with no private disclosure
channel; please don't include anything sensitive in a report.

## Design invariants

LockBadges reads lock key state and draws a window. These constraints are
enforced in the source header and should not be relaxed:

- **No keyboard hook.** State is read via `GetKeyState(key, "T")`. Keystrokes
  are never intercepted, buffered or read.
- **No inspection of other processes.** No control handles, control text or
  window titles. Only the foreground window's class, style and rectangle are
  read, solely to detect fullscreen applications.
- **No network access**, no telemetry, no update check.
- **No logging.** A debug log recording window classes or focus changes would
  be a behavioural record of the user's session.

## Deployment guidance

This script can be configured to run at every login. Anything that
autostarts should live where an unprivileged process cannot modify it,
because write access to the file means code execution in the user's session
at each logon.

Install to a location such as `C:\Program Files\LockBadges` and verify:

```powershell
icacls "C:\Program Files\LockBadges"
```

No `(M)` or `(W)` for `Users` or `Authenticated Users`. Confirm by attempting
a write from a non-elevated prompt; access denied is the expected result.

Note that moving a folder within a volume preserves its original ACL, so a
folder created elsewhere and moved into Program Files can arrive with weaker
permissions than its location implies.
