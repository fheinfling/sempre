# Security Policy

Sempre is a menu bar time tracker. It keeps your projects and time entries in a JSON file in
iCloud Drive (or locally). Its only network traffic is the update check: once a day (and when you choose
Check for Updates…) it asks GitHub for the latest release, and on Update downloads that release's zip. It never
sends your data anywhere. We take reports seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.** Instead, use GitHub's private channel:

- Go to the [**Security tab → Report a vulnerability**](https://github.com/fheinfling/sempre/security/advisories/new)
  (GitHub private vulnerability reporting is enabled on this repo).

We'll acknowledge within a few days and work with you on a fix and coordinated disclosure.

## Scope

In scope:
- Exposure of tracked data: the data file (`iCloud Drive/Sempre/sempre.json`), temporary files, logs.
- The CSV importer reading an untrusted or malformed file.
- The updater: anything that gets it to install an app that isn't a notarized Sempre signed by the same Developer ID
  team as the running one (it checks the download against the running app's own designated requirement), or to
  run code from the download before those checks pass.
- Data loss or corruption through sync between Macs.
- The build and release scripts (`build.sh`, the GitHub workflows).

Out of scope:
- Vulnerabilities in macOS or iCloud Drive itself.
- Physical access to an already-unlocked Mac.

## Release signing

Releases are signed and notarized by the `release` workflow. Its signing job runs only for `v*` tags (which only the
maintainer can create) and only after the maintainer approves it. It uses a Developer ID certificate kept just for
CI and an App Store Connect API key, both stored as secrets of the `release` environment. No other job,
pull request or fork can read them. Each release zip has a provenance attestation (`gh attestation verify`).

## Supported versions

Only the latest release / `main` is supported. Please test against the newest version before reporting.
