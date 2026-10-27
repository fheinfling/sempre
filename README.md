<img src="https://raw.githubusercontent.com/fheinfling/sempre/screenshots/icon.png" width="96" alt="Sempre app icon: a walnut metronome">

# Sempre

A small time tracker that lives in the macOS menu bar.

<p>
  <a href="https://github.com/fheinfling/sempre/actions/workflows/ci.yml"><img alt="ci" src="https://github.com/fheinfling/sempre/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/fheinfling/sempre"><img alt="coverage" src="https://codecov.io/gh/fheinfling/sempre/branch/main/graph/badge.svg"></a>
  <img alt="platform" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="swift" src="https://img.shields.io/badge/swift-6.1%2B-orange?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/fheinfling/sempre/screenshots/track-dark.png">
    <img src="https://raw.githubusercontent.com/fheinfling/sempre/screenshots/track.png" width="320" alt="Track: a running timer and the project list">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/fheinfling/sempre/screenshots/month-dark.png">
    <img src="https://raw.githubusercontent.com/fheinfling/sempre/screenshots/month.png" width="320" alt="Stats: a month of tracked time per project">
  </picture>
</p>

- Add projects (and optional subprojects), click to start and stop
- Animated metronome in the menu bar while a timer runs, with `h:mm` and the odd nudge
- Stats by week, month, year or all time, per project, with days worked
- Edit, add or delete entries; add breaks as a length or an exact time
- Syncs between Macs through iCloud Drive (`iCloud Drive/Sempre/sempre.json`)
- Imports old entries from a CSV export of Toggl, Clockify, Harvest, Timing or most other time trackers
- No third-party dependencies

Requires macOS 14 or later (Apple Silicon or Intel).

## Build

```sh
./build.sh
```

Builds a universal `build/Sempre.app`, packs `build/Sempre-<version>.zip` and installs the app to `~/Applications`.
See the top of `build.sh` for Developer ID signing and notarization. No signing material lives in this repo.

## Test

```sh
./test.sh
```

Runs the Swift Testing suite in `Tests/SempreCoreTests`. It works with Xcode or with just the Command Line Tools.

`scripts/coverage.sh` runs the same suite with code coverage, prints a summary and writes `coverage.lcov`.
CI runs it on every push and pull request and uploads it to Codecov.

## Structure

- `Sources/SempreCore`: data model, storage and sync (`Store`), formatting, CSV import. No UI.
- `Sources/Sempre`: the menu bar app (SwiftUI), the animated menu bar icon and developer flags.
- `Tests/SempreCoreTests`: tests for everything in `SempreCore`.
- `Resources/AppIcon.icns`: the app icon, drawn by `scripts/make-icon.swift`; run `scripts/make-icon.sh` after changing it.

## Install

Download `Sempre-vX.Y.zip` from [Releases](https://github.com/fheinfling/sempre/releases), unzip it and move
`Sempre.app` to Applications. Releases are signed with a Developer ID and notarized by Apple, so it opens normally.
To check that a zip was built and signed by this repo's release workflow:

```sh
gh attestation verify Sempre-vX.Y.zip --repo fheinfling/sempre
```

A zip you built yourself without `SIGN_IDENTITY` is only ad-hoc signed; on another Mac, right-click the app › Open
the first time, or run `xattr -dr com.apple.quarantine /Applications/Sempre.app`.

## Import from other apps

Export your entries as CSV from your old time tracker, then Menu `⋯` › Import CSV… and choose the file.
Projects and tasks are matched by name (ignoring case) and created when missing. Entries that are already there
(same project, start and end) are skipped, so importing the same file again only adds what's new.

Exports from Toggl, Clockify, Harvest and Timing work as they are. For anything else, make a CSV with a header row,
for example:

```csv
project,task,start,end
Client Website,Design,2026-10-01 09:00,2026-10-01 10:30
Admin,,2026-10-01 13:00,2026-10-01 13:45
```

Columns are found by their header (case, spaces and punctuation don't matter; other columns are ignored):

| Column | Header names | |
|---|---|---|
| Project | `project`, `project name`, `Projekt` | required; empty becomes "No Project" |
| Task | `task`, `subproject`, `Aufgabe` | optional; becomes a subproject |
| Start | `start`, `start date`, `from`, `begin`, `Von`; plus `start time` | required, or `date` |
| Date | `date`, `day`, `Datum` | the day when start/end only hold a time |
| End | `end`, `end date`, `stop`, `to`, `Bis`; plus `end time` | required, or `duration` |
| Duration | `duration`, `hours`, `Dauer`, `Stunden` | `1:30`, `1:30:00` or `1.5` hours |

- Separators: comma, semicolon or tab. Quoted fields are fine. UTF-8, UTF-16 or Windows-1252.
- Dates: `2026-10-01`, `01.10.2026` or `10/01/2026`. Slash dates are read month-first unless some date in the file
  only works day-first (`13/10/2026`). Times: `14:30`, `14:30:00` or `2:30 PM`.
- Times without a zone are local time; ISO 8601 timestamps with a zone (`2026-10-01T09:00:00+02:00`) are taken as is.
- An end time earlier than the start, with no date of its own, runs past midnight.
- A date with hours but no times (as Harvest exports) is laid out from 9:00, one entry after another.
- Rows without a usable start and end (such as a running timer) are skipped and counted.

## Developer flags

- `Sempre --snapshot <dir> [--real]` renders the UI to PNGs (light and dark), with demo data or (read-only) your own.
  The README screenshots come from this too: the `screenshots` workflow renders them from demo data whenever
  the UI changes on `main` and publishes them to the `screenshots` branch.

## License

MIT, see [LICENSE](LICENSE).
