# Security Policy

Sempre is a menu bar time tracker. It keeps your projects and time entries in a JSON file in
iCloud Drive (or locally), can read a Tyme 2 database once to import it, and never sends anything
over the network. We take reports seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.** Instead, use GitHub's private channel:

- Go to the [**Security tab → Report a vulnerability**](https://github.com/fheinfling/sempre/security/advisories/new)
  (GitHub private vulnerability reporting is enabled on this repo).

We'll acknowledge within a few days and work with you on a fix and coordinated disclosure.

## Scope

In scope:
- Exposure of tracked data: the data file (`iCloud Drive/Sempre/sempre.json`), temporary files
  (e.g. the working copy of a Tyme database during import), logs.
- The Tyme 2 importer reading an untrusted or malformed database.
- Data loss or corruption through sync between Macs.
- The build and release scripts (`build.sh`, the GitHub workflows).

Out of scope:
- Vulnerabilities in macOS, iCloud Drive or Tyme itself.
- Physical access to an already-unlocked Mac.

## Supported versions

Only the latest release / `main` is supported. Please test against the newest version before reporting.
