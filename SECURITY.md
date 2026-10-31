# Security policy

dkde is early software (version 0.0.x). Please treat it accordingly, and read
the notes below before running it on a machine you care about.

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue. Use
GitHub's "Report a vulnerability" button on the Security tab of this
repository (private vulnerability reporting). If that is unavailable, open an
issue that says only that you have a security report and how to reach you,
without any details.

I will acknowledge a report as soon as I can, and fix confirmed problems
before they are discussed in public. There is no bug bounty.

## What is security-relevant here

- **The administrator-password dialog** (`common.elevate`). dkde has no polkit
  agent, so it asks for your password in its own dialog and runs the command
  through `sudo -S -k`. The password goes to sudo's standard input, is wiped
  from memory afterwards, and is never put on a command line or in the
  environment. Values that users type reach the privileged scripts only as
  positional parameters, never as script text. Reports in this area are the
  most valuable.
- **The login screen** (`dkde-greeter`) talks to greetd over its socket and
  holds the password in memory only while signing in.
- **Known limits.** The Network page passes a new Wi-Fi password to `nmcli` as
  an argument, so it is briefly visible in the process list to other local
  users. Bluetooth pairing uses a no-input agent and cannot handle PINs.
  These are listed in SPEC.md.
- **Session services.** Notifications and the system tray use the user's
  session D-Bus and trust the applications on it, as other desktops do.

## Supported versions

Only the latest commit on the default branch.
