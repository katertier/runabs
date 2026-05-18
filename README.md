# runabs.sh — run Audiobookshelf without Docker

A POSIX shell script that runs [Audiobookshelf](https://www.audiobookshelf.org)
directly from source on macOS, Linux, BSD, or WSL2 — no Docker, no virtual
machine, no container runtime required.

Two guides, depending on which path you take:

- **[ABS_NO_DOCKER.md](ABS_NO_DOCKER.md)** — run ABS directly via `runabs.sh`
  with Node.js or Bun as the JavaScript runtime. Decision trees, per-OS
  prerequisites, security guidance, troubleshooting. **Start here.**
- **[ABS_APPLE_CONTAINER.md](ABS_APPLE_CONTAINER.md)** — alternative for
  Apple Silicon Macs: run ABS in Apple's native `container` CLI (each
  container in its own micro-VM) without needing Docker Desktop.

If you're not sure which is right for you, read the "Is this for you?"
decision tree in `ABS_NO_DOCKER.md` first.

## Distribution contents

| File | What it is |
|---|---|
| `runabs.sh` | The script. Strict POSIX shell, runs under `sh`/`dash`/`bash`/`posh`. Self-contained. |
| `runabs.1` | Man page. Reference for every command, flag, and environment variable. After `make install`, view with `man runabs`. |
| `Makefile` | Build/install. Targets: `install`, `uninstall`, `reinstall`, `check`, `lint`, `test`, `dist`, `help`. |
| `ABS_NO_DOCKER.md` | How to run ABS directly with `runabs.sh`. The main guide. |
| `ABS_APPLE_CONTAINER.md` | How to run ABS in Apple's `container` CLI. |
| `CHANGELOG.md` | Per-release list of changes. Skim when upgrading. |
| `LICENSE` | GPL-3.0-or-later, verbatim. |
| `SECURITY.md` | Explains why the script itself is not a security risk, and why running ABS without Docker still needs thought. Start here if you're evaluating whether to trust this script. |
| `.gitignore` | Useful if you `git init` the extracted distribution to track local edits. Ignored by people who cloned this repo from GitHub. |
| `README.md` | This file. |

## Minimum steps to get started

1. **Read [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) first** — at minimum the "Is this for you?" and "Prerequisites" sections for your OS. It also covers how to obtain the script (git / tarball / GitHub ZIP), whether you need sudo, and how to put `~/.local/bin` on your PATH. This README is an index, not a tutorial.
2. Install the prerequisites for your OS as listed there (git, ffmpeg, ffprobe, and Node.js or Bun).
3. Run:

   ```sh
   make install
   runabs.sh foreground
   ```

   `foreground` is recommended for the first run so you can watch each
   setup step. After it's working, `Ctrl+C` and use:

   ```sh
   runabs.sh start             # daemonize
   runabs.sh status            # check it
   runabs.sh install-service   # autostart at boot/login (optional)
   ```

## Before exposing to the internet

If you plan to make Audiobookshelf reachable from outside your home
network, read the [Internet exposure & security](ABS_NO_DOCKER.md#internet-exposure--security)
section of `ABS_NO_DOCKER.md` first. Audiobookshelf has had several
CVEs (XSS, SSRF, path traversal, auth bypass); that section explains
what changes between Docker, this script, and runtime choice, and
what doesn't.

**TL;DR**: put it behind a reverse proxy you control, set a strong
`ABS_JWT_SECRET`, and consider a VPN (Tailscale, WireGuard) instead of
direct public internet exposure.

## Where to look for what

| Question | Look in |
|---|---|
| Docker vs. direct vs. Apple container? | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) "Is this for you?" |
| How do I install prereqs on _my OS_? | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) "Prerequisites" |
| What does `ABS_FOO` do? | `man runabs` or [`runabs.1`](runabs.1) |
| How do I autostart at boot? | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) "Autostart" |
| Bun's sqlite binding broke | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) troubleshooting |
| Apple Silicon ffmpeg "Bad CPU type" | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) "Apple Silicon" |
| WSL2-specific gotchas | [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md) "WSL2 notes" |
| Apple `container` runtime instead | [`ABS_APPLE_CONTAINER.md`](ABS_APPLE_CONTAINER.md) |
| What changed since I last upgraded? | [`CHANGELOG.md`](CHANGELOG.md) |
| What's the script doing right now? | `runabs.sh check-config` |

## Verifying the archive

```sh
make check    # POSIX syntax-test the script against every shell installed
make lint     # shellcheck (if installed)
make test     # check + lint
```

Worth running once before you trust the script.

## License

GPL-3.0-or-later. Provided **AS IS** with no warranties. See
[`LICENSE`](LICENSE) for the full text and the top of `runabs.sh`
for the abbreviated notice.

Audiobookshelf itself is licensed separately by its authors. This script
is independent and unaffiliated.

## Reporting issues

Bugs in **this script** or its documentation → <https://github.com/katertier/runabs/issues>.
Include OS, runtime (Node or Bun) and version, and the output of
`runabs.sh check-config` if relevant.

Bugs in **Audiobookshelf itself** → upstream at
<https://github.com/advplyr/audiobookshelf/issues>.

**Security-sensitive findings**: see [`SECURITY.md`](SECURITY.md) for
scope, the script's security posture, and how to report privately.

## Downloads

The latest release is always available at
<https://github.com/katertier/runabs/releases/latest>. Specific historical
versions are linked from [`CHANGELOG.md`](CHANGELOG.md).
