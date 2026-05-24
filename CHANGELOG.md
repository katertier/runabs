# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [4.0.6] — 2026-05-24

### Fixed

- Daemon start no longer reports a false "Daemon died within N seconds" when ABS
  actually started. The startup health check now uses a POSIX `kill -0` liveness
  probe, and daemon identification (`status`/`stop`/`restart`) is done primarily
  by checking which PID is bound to the port — portable and truncation-proof —
  instead of matching `$REPO_DIR` in `ps -o args=` (which never matched the
  relatively-launched daemon and can be truncated on the BSDs). This also fixes
  `stop`/`restart` failing to find the daemon, which left orphaned processes and
  caused spurious port conflicts.
- Port-conflict handling: when the port is in use, runabs now identifies the
  offending process (PID + command) and, interactively, offers to stop it
  (SIGTERM then SIGKILL), verifying the port is freed before continuing.
  Non-interactive contexts abort cleanly with guidance instead of letting ABS
  crash with an `EADDRINUSE` stack trace. Port detection now also covers the BSDs
  (`sockstat`) and Linux `fuser`, in addition to lsof/ss/netstat.
- Runtime detection now finds Bun (and Node) in well-known off-PATH locations
  (`$BUN_INSTALL/bin`, `~/.bun/bin`, Homebrew dirs), so Bun-based autostart via
  launchd/systemd/cron no longer fails with "Bun is not installed" when
  `~/.bun/bin` is not on the service's PATH.

## [4.0.5] — 2026-05-24

### Fixed

- Bun: stop the Socket.IO "connected → transport close → reconnect" loop that
  appears whenever ABS runs under a `RouterBasePath` (the default
  `/audiobookshelf`). ABS opens a second Socket.IO server for the base path, so
  both engine.io instances see every WebSocket upgrade. Under Bun,
  `socket.bytesWritten` is not tracked on upgraded sockets, so the non-matching
  server's stray-upgrade cleanup (`destroyUpgradeTimeout`, default 1000 ms)
  wrongly ended the live connection after ~1 s. The Bun `socket.io-patch.js` now
  forces `destroyUpgrade: false`, which applies to both servers via the
  constructor wrap. The Node runtime is unaffected.
- Bun: removed the no-op `wsEngine: 'ws'` string from the patch — engine.io v6
  expects a constructor, not a module name, and `ws` is already the default.

## [4.0] — 2026-05

Initial public release.

### Distribution layout

- `README.md` is a short orientation/landing page (suitable for GitHub).
- `ABS_NO_DOCKER.md` is the main guide: running ABS via `runabs.sh` directly.
- `ABS_APPLE_CONTAINER.md` is the alternative path: running ABS in Apple's
  native `container` CLI on Apple Silicon.
- `SECURITY.md` explains the security posture of the script itself
  (versus the security tradeoffs of running ABS without a container).
- `CHANGELOG.md`, `LICENSE`, `runabs.1` (man page), `Makefile`,
  `.gitignore`, `.shellcheckrc` complete the archive.

### Maintainer notes

For future releases, run `make bump TO=X.Y` to update all three places in
one shot (refuses to run on a dirty git tree):

- `ABS_RUN_VERSION` near the top of `runabs.sh`
- `.TH RUNABS 1 "Month Year" "runabs.sh X.Y" "User Commands"` in `runabs.1`
- A new version heading + stub sections + reference link in `CHANGELOG.md`

After bumping, edit the CHANGELOG stub with real notes, run `make test`,
build with `make dist`, then commit, tag, push, and create the GitHub
release.

### Features

- Runs Audiobookshelf from source on macOS, Linux, BSD, and WSL2.
- Dual runtime: Node.js or Bun, selectable per installation.
- Interactive runtime choice persisted to `$ABS_ROOT/.runtime`.
- Bun installation via official installer with explicit consent prompt.
- Native ffmpeg auto-detection on Apple Silicon (Homebrew, MacPorts) even
  when those directories aren't on `$PATH` (handles launchd/cron contexts).
- nunicode dylib pre-download for both runtimes, avoiding ABS BinaryManager's
  ~30 second first-launch delay.
- Log rotation by size (`50M`, `1G`) or age (`30d`), single-generation.
- Lock file per `$ABS_ROOT` prevents concurrent starts of the same instance.
- Autostart via launchd (macOS), systemd (Linux), or crontab `@reboot` fallback.
- Commands: `start`, `foreground`, `stop`, `restart`, `status`, `logs`,
  `check-update`, `check-config`, `install-service`, `uninstall-service`,
  `init-config`, `rebuild-sqlite`.
- `--debug` flag and `ABS_DEBUG=1` env var for shell xtrace troubleshooting.
- Per-OS prerequisite documentation for macOS (Homebrew + MacPorts), Debian,
  Fedora, Arch, Alpine, openSUSE, FreeBSD, OpenBSD/NetBSD, WSL2.

### Validation & safety

- RFC 1123 hostname validation, strict IPv4 (no leading zeros), IPv6 with
  hextet count and length checks, port-range validation, boolean and
  absolute-path validation.
- JS-safe string validation prevents injection into the generated `dev.js`.
- Refuses to remove `$REPO_DIR` if it exists and contains non-ABS content.
- Warns before discarding local git modifications on update (auto-skips in
  non-interactive contexts like launchd/cron).
- Defers SIGINT/SIGTERM during the graceful-stop window to prevent half-killed
  daemons.
- Port-conflict check runs early (before the 2-3 minute install) and again
  just before launch.
- Defends against empty `ABS_ROOT` or `ABS_PORT` values in config files.
- Uses `mktemp` rather than predictable `/tmp/$$` paths for error capture
  (symlink-attack resistance on multi-user systems).

### Portability

- Strict POSIX shell. Tested under `sh`, `dash`, `bash`, `posh`.
- No `grep -o`, `grep -E`, `sed -E`, bare `head -N`/`tail -N`, or other
  GNU/BSD extensions.
- shellcheck clean (with `-e SC3040,SC2015,SC2034,SC2154`).

### Distribution

- Self-contained Makefile with `install`, `uninstall`, `check`, `lint`,
  `test`, `dist` targets.
- Man page (`runabs.1`).
- Full README with decision trees, per-OS prerequisites, internet-exposure
  security guidance.
- Separate ABS_APPLE_CONTAINER.md for running ABS in Apple's native `container`
  CLI as an alternative to Docker Desktop.
- GPL-3.0-or-later license file (verbatim).

[4.0.6]: https://github.com/katertier/runabs/releases/tag/v4.0.6
[4.0.5]: https://github.com/katertier/runabs/releases/tag/v4.0.5
[4.0]: https://github.com/katertier/runabs/releases/tag/v4.0
