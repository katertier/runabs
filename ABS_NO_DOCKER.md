# Running Audiobookshelf without Docker — the `runabs.sh` guide

**Run [Audiobookshelf](https://www.audiobookshelf.org) from source on macOS, Linux, or BSD — without Docker.**

A strict POSIX shell script that clones the upstream Audiobookshelf repository, installs its dependencies, builds the web client, and runs it as a daemon or in the foreground with your choice of Node.js or Bun.

```sh
runabs.sh start          # daemon (default)
runabs.sh foreground     # interactive, with file-watch
runabs.sh check-config   # validate everything before starting
runabs.sh install-service  # autostart on boot
```

---

## Table of Contents

1. [Is this for you?](#is-this-for-you) — decision tree
2. [Docker vs. running directly](#docker-vs-running-directly)
3. [Choosing a runtime: Bun vs. Node.js](#choosing-a-runtime-bun-vs-nodejs)
4. [Prerequisites](#prerequisites) — per-OS install instructions
5. [Install](#install)
6. [First run](#first-run)
7. [Configuration](#configuration)
8. [Autostart](#autostart)
9. [Internet exposure & security](#internet-exposure--security)
10. [Troubleshooting](#troubleshooting)
11. [Command reference](#command-reference)
12. [Uninstall](#uninstall)
13. [License](#license)

---

## Is this for you?

```
Are you running Linux/macOS/BSD on a machine you control?
├── No  → use the official hosted/Docker setup
├── Windows
│   │
│   Are you willing to use WSL2 (Linux on Windows)?
│   ├── No   → use Docker Desktop instead
│   └── Yes  → this script works inside WSL2;
│              see "WSL2 notes" under Prerequisites
└── Yes
    │
    Do you want it to "just work" with zero shell?
    ├── Yes → use the official Docker image
    └── No / "I run things from source"
        │
        Are you on Linux on bare metal or in a Linux VM?
        ├── Yes → Docker is fine, but this script also works.
        │         Pick based on your preference.
        └── On macOS or BSD?
            │
            Do you want the server to use your machine's
            ffmpeg, sqlite, networking directly (no VM layer)?
            ├── Yes  → ★ runabs.sh is for you ★
            └── No   → Docker is fine (it'll spin up a Linux VM)

    ⚠  Planning to expose ABS to the internet (not just your LAN)?
       The runtime and container choice barely change the risk;
       application-level vulnerabilities dominate. Read
       "Internet exposure & security" below before deciding —
       or skip exposure entirely and use a VPN like Tailscale.
```

**Short version:** if you're on macOS or BSD and you want native performance + native file/network access without Docker's VM-in-the-middle, this script is the path. If you're on Linux, both this script and Docker work — pick whichever fits your habits. If you're on Windows, you'll be in a VM either way (WSL2 or Docker Desktop); pick whichever you're more comfortable with. **If the server will be reachable from outside your LAN, jump to [Internet exposure & security](#internet-exposure--security) before going further.**

## Docker vs. running directly

|  | Docker | runabs.sh (direct) |
|---|---|---|
| **Linux** | Native containers, very low overhead | Native, no overhead |
| **macOS** | Runs a Linux VM under the hood (Docker Desktop / OrbStack / Colima) | Native, no VM |
| **Windows** | Native via WSL2 (which is a Linux VM) | Works under WSL2 (see [WSL2 notes](#wsl2-notes)) |
| **BSD** | Limited / unsupported by upstream | Native, no VM |
| **Resource overhead** | VM RAM/CPU on macOS/Windows; ~negligible on Linux | None |
| **ffmpeg** | Bundled in image | You install it (recommended)<sup>†</sup>, or ABS downloads it |
| **File access** | Bind-mounts (slow on macOS) | Direct filesystem |
| **Upgrades** | `docker pull && restart` | `runabs.sh restart` (git pull built-in) |
| **First-run setup**<sup>‡</sup> | ~120-150 MB image pull (1-3 min), plus Docker itself if not installed (~500 MB on macOS/Windows) | 2-3 min clone + dep install + client build |
| **Subsequent starts** | Instant | Instant |
| **Autostart** | Docker's restart policy | launchd / systemd / cron |

<sup>†</sup> **Apple Silicon caveat:** if you run runabs.sh directly, install `ffmpeg` natively (Homebrew or MacPorts) before first start. ABS's built-in downloader fetches x86_64 binaries that fail with `Bad CPU type` on arm64. The script detects this and refuses to start without native binaries. Docker isn't affected because the container has its own bundled `ffmpeg`.

<sup>‡</sup> **First-run setup times are one-off.** After that, both options start instantly. Direct setup time also assumes you don't already have Node.js/ffmpeg installed — if you do, runabs.sh's first run drops to ~1-2 min (just the ABS clone + npm install + client build).

**The macOS VM thing.** Docker doesn't run containers natively on macOS — it runs a small Linux VM (via Apple's Virtualization framework, or HyperKit on older Docker Desktop, or QEMU on alternatives like Colima/Lima). Your containers run inside that VM. This is fine for most workloads, but for an audiobook server it means:

- Library files are accessed across the VM boundary (slower than native, sometimes noticeably so for large libraries).
- ffmpeg transcoding runs in the VM, sharing the host CPU but with extra scheduling overhead.
- You're paying ~1-2 GB of RAM for the VM itself, idle.

If those things matter to you, run directly. If they don't, Docker is simpler.

**Apple Silicon: a third option.** If you're on an Apple Silicon Mac running macOS 15 or 26, Apple ships its own native container runtime (`container`) that uses one micro-VM per container, no Docker Desktop required. See [ABS_APPLE_CONTAINER.md](ABS_APPLE_CONTAINER.md) for a full walkthrough including pros/cons against both Docker Desktop and `runabs.sh`.

## Choosing a runtime: Bun vs. Node.js

Audiobookshelf is written for Node.js. The script also supports Bun (a faster, drop-in-ish replacement) with a small runtime patch for Socket.IO compatibility.

```
Do you know what Bun is and want to use it specifically?
├── Yes → use Bun
└── No
    │
    Are you running this in production and want maximum stability?
    ├── Yes → use Node.js (upstream-supported)
    └── No
        │
        Do you care about ~25% faster startup and slightly
        lower memory usage at runtime?
        ├── Yes → try Bun. Worst case, switch back.
        └── No  → use Node.js
```

Detailed comparison:

|  | Node.js | Bun |
|---|---|---|
| **Upstream-supported** | ✓ (official) | ✗ (community workaround) |
| **Maturity** | Mature, decade-plus | Newer, still evolving |
| **Auto-install by this script** | ✗ (instructions only) | ✓ (with explicit consent) |
| **Apple Silicon (arm64)** | Native | Native |
| **Startup time** | Baseline | ~25% faster |
| **Memory at runtime** | Baseline | ~10-15% lower |
| **Socket.IO** | Works as-is | Needs a runtime patch (the script adds it automatically) |
| **sqlite3 native bindings** | Builds at `npm install` | Rebuilt via `npm rebuild` post-install |
| **`nunicode` extension** | Works (verified) | Works (verified) |
| **Risk profile** | Battle-tested | Edge cases possible; you may hit them |

**Recommendation:** pick **Node.js** unless you have a specific reason to want Bun. If you do want to try Bun, the script can install it for you on request.

## Prerequisites

The script needs three things at minimum: **a POSIX shell** (already present on any Unix), **git**, **ffmpeg** + **ffprobe**, and **a JavaScript runtime** (Node.js or Bun).

A quick what's-what for the unfamiliar:

- **git** — version control. The script clones Audiobookshelf's source from GitHub.
- **ffmpeg** — multimedia toolkit. Audiobookshelf uses it for audio transcoding, metadata extraction, podcast downloads, and chapter extraction.
- **ffprobe** — comes with ffmpeg; inspects media files.
- **Node.js** — the JavaScript runtime Audiobookshelf is written for. Comes with **npm** (its package manager).
- **Bun** — an alternative JavaScript runtime, faster but newer.
- **unzip** (optional) — for the nunicode unicode-search extension. Pre-installed on macOS.

### macOS

Two popular package managers; both work. Pick one and stick with it.

**[Homebrew](https://brew.sh)** is the most common. It installs to `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel. No sudo needed for `brew install`.

```sh
# Install Homebrew itself (if you don't have it):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Required for runabs.sh:
brew install git ffmpeg

# Pick one runtime:
brew install node       # Node.js + npm
# or:
brew install bun        # Bun (the script can also install it for you)
```

**[MacPorts](https://www.macports.org)** is an older, BSD-style ports system. Installs to `/opt/local`, needs sudo.

```sh
# Install MacPorts from https://www.macports.org/install.php (DMG installer), then:
sudo port install git ffmpeg

# Pick one runtime:
sudo port install nodejs20 npm10       # Node.js + npm
# or:
sudo port install bun                  # Bun
```

> **Apple Silicon ffmpeg gotcha:** Audiobookshelf's built-in `BinaryManager` downloads **macOS x86_64** ffmpeg binaries when ffmpeg isn't in PATH. On Apple Silicon (M1/M2/M3/M4) those binaries fail with `Bad CPU type in executable`. The fix is to install ffmpeg natively (Homebrew or MacPorts as shown above) **before first start**.
>
> The script automatically detects Homebrew (`/opt/homebrew/bin`, or `/usr/local/bin` on older Intel-Homebrew setups) and MacPorts (`/opt/local/bin`) installs, even if those directories aren't in your `$PATH` — so it works correctly under launchd, cron, or a stripped-down shell environment where `command -v ffmpeg` would otherwise fail.
>
> If you somehow start ABS without native ffmpeg and the bad binaries get downloaded into `$ABS_ROOT/audiobookshelf/server/bin/`, delete that directory after installing native ffmpeg:
>
> ```sh
> rm -rf $ABS_ROOT/audiobookshelf/server/bin
> brew install ffmpeg     # if not already done
> runabs.sh restart
> ```
>
> The script will then re-detect the native binaries and pass their paths to ABS via `ABS_FFMPEG`/`ABS_FFPROBE`, bypassing the downloader entirely.
>
> This problem does **not** affect Docker or Apple's `container` runtime: those run ABS in a Linux arm64 VM with arm64 ffmpeg already in the image.

### Debian / Ubuntu / Mint / Pop!_OS

```sh
sudo apt-get update
sudo apt-get install git ffmpeg unzip curl

# Node.js: distro version is often too old. Either:
#  (a) Use NodeSource for a current LTS:
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

#  (b) Or use the distro version (may be old; the script warns if <20):
sudo apt-get install nodejs npm

# Or pick Bun instead — the script can install it for you on first run.
```

### Fedora / RHEL / Rocky / Alma

```sh
sudo dnf install git ffmpeg unzip curl

# Node.js: enable the module for a current major version
sudo dnf module install nodejs:20/common
# or just:  sudo dnf install nodejs npm
```

> **RHEL/Rocky/Alma:** `ffmpeg` is in [RPM Fusion](https://rpmfusion.org), not the default repos. Enable it first:
> ```sh
> sudo dnf install https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm
> ```

### Arch / Manjaro / EndeavourOS

```sh
sudo pacman -S git ffmpeg unzip nodejs npm
# Bun is in AUR:  yay -S bun-bin   (or  paru -S bun-bin)
```

### Alpine

```sh
apk add git ffmpeg unzip nodejs npm curl
# (Bun is available but compiled against glibc; on musl Alpine you'll want the musl build.
#  Easier path on Alpine: use Node.)
```

### openSUSE

```sh
sudo zypper install git ffmpeg unzip nodejs20 npm20
```

### FreeBSD

```sh
sudo pkg install git ffmpeg unzip node20 npm-node20
# Bun is in ports too: sudo pkg install bun
```

### OpenBSD / NetBSD

```sh
# OpenBSD:
doas pkg_add git ffmpeg unzip node

# NetBSD (pkgsrc):
sudo pkgin install git ffmpeg unzip nodejs
```

### WSL2 notes

WSL2 is a real Linux VM with a real kernel, so the script's Linux code paths apply: use the **Debian/Ubuntu** (or whichever distro you installed) instructions above for installing prerequisites. The script auto-detects WSL2 as `Linux`.

A few WSL-specific things to know:

**File location.** Keep `$ABS_ROOT` on the Linux filesystem (e.g., `~/audiobookshelf`), **not** on a Windows mount (`/mnt/c/...`). Cross-boundary I/O through the 9P filesystem is dramatically slower — measurable in seconds per directory scan for a large audiobook library. If you must keep your media library on a Windows drive (because of disk space), at least keep ABS's config, metadata, and the cloned repo on the Linux side; only point ABS's library config at the Windows mount.

**Reaching ABS from Windows.** By default, WSL2 forwards localhost: a server bound to `0.0.0.0:13378` in WSL is reachable as `http://localhost:13378` from your Windows browser. No setup needed.

**Reaching ABS from the LAN** (phones, other machines) is trickier because WSL2 sits behind NAT. Two options:

1. **Mirrored networking mode** (Windows 11 22H2+, the simpler option). In `%USERPROFILE%\.wslconfig`:
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```
   Then `wsl --shutdown` and restart your WSL session. With mirrored mode, WSL2 shares the host's network interfaces, and ABS will be reachable on the LAN at the Windows host's IP.

2. **Port forwarding** (older Windows or if mirrored mode causes issues). From PowerShell as Administrator:
   ```powershell
   $wslIP = (wsl hostname -I).Trim().Split()[0]
   netsh interface portproxy add v4tov4 listenport=13378 listenaddress=0.0.0.0 connectport=13378 connectaddress=$wslIP
   New-NetFirewallRule -DisplayName "Audiobookshelf" -Direction Inbound -LocalPort 13378 -Protocol TCP -Action Allow
   ```
   The WSL IP changes on every restart, so you'll want to script this and run it at Windows login.

**systemd.** WSL2 supports systemd since version 0.67.6 (September 2022), but it's **disabled by default**. Enable it in `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then `wsl --shutdown` (from PowerShell on the Windows side) and reopen WSL. With systemd enabled, `runabs.sh install-service` will use a systemd user unit. Without systemd, the script falls back to a crontab `@reboot` entry — but **that won't fire on WSL**, because WSL doesn't go through a traditional boot. See the autostart caveat below.

**Autostart on WSL2.** The WSL2 VM doesn't "boot" the way a real Linux system does — it starts on demand when you (or Windows) launches a WSL session. A few implications:

- Systemd user units start when WSL starts, which is when *you* open a WSL terminal. To make systemd start at Windows login, set `wsl --exec true` (or similar) as a Windows scheduled task at login. Enable lingering with `sudo loginctl enable-linger $USER` so the unit stays running after you close the terminal.
- The crontab `@reboot` fallback doesn't work on WSL — `cron` itself may not even be running, and "reboot" in the WSL sense is `wsl --shutdown` followed by a re-open, which doesn't fire `@reboot`. Use systemd instead.

**Recommended WSL2 setup:**

```sh
# Inside WSL (Ubuntu/Debian):
sudo apt-get update
sudo apt-get install git ffmpeg unzip nodejs npm

# Enable systemd (in /etc/wsl.conf, then `wsl --shutdown` from Windows):
# [boot]
# systemd=true

# Then:
make install
runabs.sh foreground   # first run
sudo loginctl enable-linger $USER   # keep the service alive after terminal closes
runabs.sh install-service
```

### Verify your prerequisites

After installing, this should all succeed:

```sh
git --version
ffmpeg -version | head -1
ffprobe -version | head -1
node --version   # or:  bun --version
```

Then run `runabs.sh check-config` to confirm the script sees them.

## Install

The repository ships with a `Makefile` that installs the script and its man page.

### User install (no sudo, recommended)

```sh
make install
# Installs to:
#   ~/.local/bin/runabs.sh
#   ~/.local/share/man/man1/runabs.1
```

If `~/.local/bin` isn't on your `$PATH`, add to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```sh
export PATH="$HOME/.local/bin:$PATH"
export MANPATH="$HOME/.local/share/man:$MANPATH"
```

### System-wide install (needs sudo)

```sh
sudo make install PREFIX=/usr/local
# Installs to:
#   /usr/local/bin/runabs.sh
#   /usr/local/share/man/man1/runabs.1
```

### Custom paths

```sh
make install PREFIX=/opt/runabs       # → /opt/runabs/bin/runabs.sh
make install BINDIR=/tmp MAN1DIR=/tmp # → /tmp/runabs.sh and /tmp/runabs.1
```

### Other Makefile targets

| Target | Effect |
|--------|--------|
| `make help` | Show targets and current install paths |
| `make install` | Install script, man page, README, LICENSE |
| `make uninstall` | Remove installed files |
| `make reinstall` | Uninstall, then install |
| `make check` | Syntax check across `sh`, `dash`, `bash`, `posh`, etc. |
| `make lint` | Run `shellcheck` if available |
| `make test` | `check` + `lint` |
| `make dist` | Build a versioned `runabs-X.Y.tar.gz` distribution archive |

### Or just download and run

You don't have to install at all. The script is self-contained — but how you got it determines whether the executable bit is set on the file.

**Direct download** (single file, executable bit must be set manually):

```sh
curl -fsSL https://github.com/katertier/runabs/releases/latest/download/runabs.sh -o ~/runabs.sh
chmod +x ~/runabs.sh
~/runabs.sh start
```

**Distribution archive** (`runabs-X.Y.tar.gz`, executable bit preserved):

```sh
tar -xzf runabs-4.0.tar.gz
cd runabs-4.0
./runabs.sh start          # works directly - tar preserves the +x bit
# or:
make install               # install to ~/.local/bin
```

**GitHub "Download ZIP"** (executable bit *not* preserved — GitHub's ZIPs lose Unix permissions):

```sh
unzip runabs-main.zip
cd runabs-main
chmod +x runabs.sh         # restore the bit that the ZIP format dropped
./runabs.sh start
# or, equivalently, sidestep the bit entirely:
sh runabs.sh start
# or just let make install fix it for you:
make install               # install -m 755 forces the right mode regardless
```

The `chmod +x` step is only needed for the GitHub ZIP path. `git clone` and `tar.gz` both preserve permissions, and `make install` always installs the script as mode 755 regardless of the source.

## First run

Assuming you've installed the prerequisites for your OS:

```sh
runabs.sh foreground       # recommended for the first run
```

The script will:

1. Check prerequisites (and exit with a pointer to this README if anything is missing).
2. Prompt you to pick Node.js or Bun. If you pick Bun and it's not installed, it'll offer to install Bun for you.
3. Clone Audiobookshelf into `$ABS_ROOT/audiobookshelf` (~50 MB).
4. Install dependencies (~400 MB, 1–2 minutes).
5. Build the web client (~30 seconds).
6. Start the server and print the URL to visit.

All runtime state lives under `$ABS_ROOT` (default `~/audiobookshelf`). The script itself can live anywhere.

Once it's working, switch to daemon mode for ongoing use:

```sh
runabs.sh stop      # exit foreground first (Ctrl+C also works)
runabs.sh start     # daemonize
runabs.sh status    # check it's up
```

## Configuration

Config is read in priority order, highest first:

1. **Environment variables** — `ABS_PORT=8080 runabs.sh`
2. **`~/.env_abs`** — user-global
3. **`.env`** next to the script — directory-local
4. **Hardcoded defaults** in the script

Both env files use POSIX shell syntax (sourced by the shell).

Generate a commented template:

```sh
runabs.sh init-config           # writes $ABS_ROOT/.env
runabs.sh init-config --home    # writes ~/.env_abs
```

Validate your config:

```sh
runabs.sh check-config
```

This prints a per-section report and exits non-zero on any failure.

### Common settings

```sh
ABS_HOST=192.168.1.10           # bind to a specific interface
ABS_PORT=8080                   # non-default port
ABS_RUNTIME=node                # or bun, or /opt/homebrew/bin/bun
ABS_ROUTER_BASE_PATH=""         # serve at root, not /audiobookshelf
ABS_AUTO_UPDATE=false           # don't pull upstream on every restart
ABS_LOG_ROTATE=200M             # rotate the daemon log at 200 MB
ABS_LOG_ROTATE=30d              # ...or after 30 days
ABS_BUN_SQLITE_REBUILD=always   # force sqlite3 rebuild on every Bun install (default: auto)
```

For the full list, see `man runabs`.

### Log rotation

`ABS_LOG_ROTATE` accepts a size or an age:

| Value | Meaning |
|-------|---------|
| `50` | 50 megabytes (bare number = MB) |
| `100K`, `100KB`, `100KiB` | 100 kilobytes |
| `100M`, `100MB`, `100MiB` | 100 megabytes |
| `1G`, `1GB`, `1GiB` | 1 gigabyte |
| `30d` | rotate when the active log is older than 30 days |

Units are case-insensitive and binary (powers of 1024). Rotation is single-generation: `audiobookshelf.log` → `audiobookshelf.log.1`, overwriting any previous `.1`. For richer rotation (multiple generations, compression), point `logrotate(8)` at the file instead.

This setting only affects the **script's daemon log** (stdout/stderr capture, mostly empty on a healthy run). Audiobookshelf's own structured logs live under `$ABS_ROOT/config/logs/` and are managed by ABS itself.

## Autostart

Install a service that starts Audiobookshelf at boot/login:

```sh
runabs.sh install-service
```

| Platform | Service installed |
|----------|-------------------|
| macOS | launchd user agent (`~/Library/LaunchAgents/org.audiobookshelf.server.plist`) |
| Linux with systemd | systemd user unit (`~/.config/systemd/user/audiobookshelf.service`) |
| Other (BSDs, Linux without systemd) | `@reboot` crontab entry + wrapper at `~/.audiobookshelf-autostart.sh` |

The runtime path and `ABS_AUTO_UPDATE` value at install time are baked into the service. Changes to `.env` files are picked up at the next service start; changes to the runtime require:

```sh
runabs.sh uninstall-service
ABS_RUNTIME=bun runabs.sh install-service
```

Removal:

```sh
runabs.sh uninstall-service
```

On systemd, you may want to enable lingering so the service starts at boot (not just at login):

```sh
sudo loginctl enable-linger $USER
```

## Internet exposure & security

If you're exposing Audiobookshelf to the internet (reverse proxy, port forward, Cloudflare tunnel, etc.), the threat model changes substantially. **All four combinations of {Docker, direct} × {Node, Bun} face the same application-layer threats**, but they differ in blast radius if those threats are exploited.

### What dominates: Audiobookshelf itself

Most actual ABS vulnerabilities are application-level, not runtime or container-level. Recent examples (do read the project's GitHub Security Advisories before deciding to expose ABS):

- **Stored & reflected XSS via metadata** (CVE-2026-27963, CVE-2026-27973, CVE-2026-27974, CVE-2025-46338) — malicious audiobook metadata executes JavaScript in other users' browsers.
- **OIDC token exfiltration** (CVE-2025-57800).
- **Authentication bypass** (CVE-2025-25205).
- **Path traversal** (CVE-2024-43797) — non-admin users could write to arbitrary directories.
- **Unauthenticated SSRF** (pre-2.7.0) — attacker could trigger HTTP requests from the server.

None of these care whether you're on Node or Bun, Docker or direct. **Keeping ABS updated is the single most important thing.** The script's default `ABS_AUTO_UPDATE=true` helps with this; consider running `runabs.sh check-update` periodically if you've disabled auto-update.

### What changes between configurations: blast radius

|  | Direct (runabs.sh) | Docker |
|---|---|---|
| **Filesystem reach if path traversal is exploited** | Anywhere your user can read/write | Only mounted volumes |
| **Network reach if SSRF is exploited** | Host LAN + host loopback (printer admin, router, internal APIs) | Container LAN; host loopback requires explicit `host.docker.internal` or `--network=host` |
| **Kernel attack surface if RCE escalates** | Direct kernel access | Namespace + seccomp + (optionally) AppArmor/SELinux boundary |
| **User identity** | Your shell user | Container UID (often non-root) |
| **System lib patching** | Your OS patches `ffmpeg`, OpenSSL, etc. via package manager | Image rebuild needed; depends on image maintainer |

**The honest summary:** Docker gives you better blast-radius containment for free. Direct gives you faster system-library patching (you control it) and zero VM/container overhead. Neither prevents the actual vulnerability — both rely on you patching ABS promptly.

### Practical hardening if exposing to the internet

These apply to **all four** combinations (Node/Bun, Docker/direct):

1. **Put ABS behind a reverse proxy you control** (Caddy, nginx, Traefik). Terminate TLS there. Do not expose ABS's port directly.
2. **Require authentication at the proxy layer** in addition to ABS's own auth — basic auth, OIDC, or a service like Authelia/authentik. Defense in depth; ABS auth has been bypassed before.
3. **Don't run as root.** The script never asks for sudo; the install service runs as your user. If you set `runabs.sh install-service` system-wide, run it as a dedicated low-privilege user, not root.
4. **Set `ABS_JWT_SECRET`** to a strong random value (32+ characters). The script warns if it's shorter. Don't let ABS auto-generate one if you intend to expose to the internet — pin it to something you control.
5. **Don't disable SSRF protection** (`ABS_DISABLE_SSRF=1`). The default filter exists because SSRF vulnerabilities have been found before.
6. **Subscribe to ABS's GitHub Security Advisories** at <https://github.com/advplyr/audiobookshelf/security/advisories>. Don't wait for CVEs to hit news aggregators.
7. **Rate-limit at the proxy.** Login endpoints especially. Brute-forcing weak passwords is the most common attack on self-hosted services.
8. **Network segmentation:** if running direct on your main desktop or NAS, consider firewalling ABS to a specific interface (`ABS_HOST=10.0.0.5`) so an SSRF can't trivially reach your internal LAN.

### Node vs. Bun specifically

The runtime choice barely affects security posture either way:

| Concern | Node.js | Bun |
|---------|---------|-----|
| **Patch cadence** | Mature, regular security releases on a known schedule | Newer; patches are released, but the security disclosure process is younger |
| **JIT/runtime CVEs** | V8 (well-audited; CVEs do appear) | JavaScriptCore (well-audited in WebKit context; less attention from server-side researchers) |
| **Supply chain (npm)** | Identical — both run the same `package.json` | Identical |
| **Hardening primitives** | `--frozen-intrinsics`, experimental Permissions API, `--disable-proto`, `--no-experimental-fetch` etc. | Fewer documented hardening flags |
| **ABS application bugs** | Same | Same |

**If "security stability" is a primary consideration: pick Node.** Not because Bun is insecure, but because Node has a longer track record of coordinated security disclosure for server-side workloads, and the runtime hardening flags are more mature. For a hobby internet-exposed setup, both are reasonable.

### Docker vs. direct, specifically for internet exposure

- **If your library data is precious and irreplaceable, Docker's containment is a meaningful safety net** against a path-traversal-class vulnerability that lets an attacker write to arbitrary paths. The container can only see its mounted volumes.
- **If you have backups and your OS user already only has access to what you intend to share, the gap narrows.** A path traversal that can read anywhere the user can read isn't dramatically worse than one that can read your library volume.
- **For network-attached storage or other internal services on the same machine,** the Docker bridge network gives a layer of separation that direct execution does not. SSRF in direct mode can hit `localhost:8080` (your other service); in Docker it generally can't.
- **For the security of the host kernel itself,** Docker adds a meaningful (not bulletproof) namespace + seccomp boundary. Several kernel privilege escalation CVEs have been mitigated by Docker's default seccomp profile.

### When this script is the wrong choice for internet exposure

Be honest with yourself:

- You **don't keep up with security advisories** and won't notice when ABS releases a patch → use Docker with `watchtower` or similar auto-update tooling, **not** this script with `ABS_AUTO_UPDATE=false`.
- You **want maximum sandboxing** for an untrusted-by-default workload → use Docker or even Podman with rootless mode, not direct execution.
- You **don't want to manage TLS, reverse proxy, fail2ban, etc.** → consider not exposing ABS to the internet at all; use a Tailscale/WireGuard VPN to reach it from outside your LAN instead. This is by far the safest option.

## Troubleshooting

### Run `check-config` first

Almost every reported issue ("won't start", "wrong URL", "missing ffmpeg") shows up clearly in `check-config` output. Run it before opening any other tool.

```sh
runabs.sh check-config
```

If `check-config` is clean and you still have a problem with the script, open an issue at <https://github.com/katertier/runabs/issues> and include its output. Bugs in **Audiobookshelf itself** (rather than this script) belong upstream at <https://github.com/advplyr/audiobookshelf/issues>.

### "Required dependencies missing"

The script lists exactly what's missing and gives a one-line install hint. For the full per-OS instructions, see [Prerequisites](#prerequisites) above.

### Daemon dies immediately

The script polls for 5 seconds after `start`. If the process dies in that window, the last 20 log lines are dumped to stderr. Common causes:

- **Port already in use.** Free `$ABS_PORT` or set a different one.
- **Missing `ffmpeg`/`ffprobe` on Apple Silicon.** Install it via Homebrew or MacPorts; the script will refuse to start without native binaries.
- **Broken `node_modules` from a runtime switch.** Delete the trees and rerun.

### "Another instance is running"

The script uses a directory lock at `$ABS_ROOT/.runabs.lock`. If a previous run crashed without cleanup:

```sh
rm -rf $ABS_ROOT/.runabs.lock
```

### Port conflict

```sh
ABS_PORT=8080 runabs.sh restart
```

For multiple ABS instances on one machine, use distinct `ABS_ROOT` directories — the lock, PID file, log, and runtime choice are all per-`ABS_ROOT`.

### Reset everything

```sh
runabs.sh stop
rm -rf $ABS_ROOT/audiobookshelf   # the cloned source tree
runabs.sh start                   # re-clones, re-installs, re-builds
```

Your library data, config, and metadata live under `$ABS_ROOT/config` and `$ABS_ROOT/metadata` — those are **not** touched.

### Bun: sqlite3 fails to load (no unicode search)

Audiobookshelf uses the npm `sqlite3` package — not Bun's built-in `bun:sqlite` — because it needs `loadExtension()` to load the `libnusqlite3` unicode search dylib (the script pre-downloads this for you under `$ABS_ROOT/nunicode/`).

Bun's package install occasionally skips the postinstall step that compiles `sqlite3`'s native binding (`node_sqlite3.node`). When that happens, ABS starts but unicode search returns nothing useful, and the logs show a `loadExtension` failure.

The script handles this automatically: after `bun install`, it checks whether `node_modules/sqlite3/build/Release/node_sqlite3.node` exists. If it doesn't, the script runs `npm rebuild sqlite3` to build it.

**Controlling the behavior:**

```sh
# Default - rebuild only if the binding is missing
ABS_BUN_SQLITE_REBUILD=auto

# Always rebuild on every start (paranoid mode)
ABS_BUN_SQLITE_REBUILD=always

# Never auto-rebuild (you'll build it yourself)
ABS_BUN_SQLITE_REBUILD=never
```

**Forcing a rebuild manually:**

```sh
runabs.sh rebuild-sqlite
```

This works on an existing installation without going through the full `start` flow. Use it when:

- You changed Bun versions and want to be sure the binding still works.
- The `auto` check passed (file exists) but unicode search is still broken — the binding may have been built against an incompatible libc or against a different Node ABI.
- You disabled the auto-rebuild (`ABS_BUN_SQLITE_REBUILD=never`) and now want to invoke it on demand.

**Requirements:** the rebuild calls `npm rebuild sqlite3`, so `npm` must be on `PATH`. The rebuild itself doesn't *run* Node — it just uses npm to drive `node-gyp`. If you went all-in on Bun and don't have Node/npm installed at all, install just enough Node to get `npm` (`brew install node`, `apt-get install npm`, etc.) — you don't have to use it as the runtime.

### Switching runtime

```sh
rm $ABS_ROOT/.runtime
rm -rf $ABS_ROOT/audiobookshelf/node_modules $ABS_ROOT/audiobookshelf/client/node_modules
runabs.sh start
```

The script detects mismatched runtimes and prompts you to clean up.

### Logs

```sh
runabs.sh logs                          # tail -f the daemon stdout/stderr log
tail $ABS_ROOT/audiobookshelf.log.1     # previous (rotated) log
ls $ABS_ROOT/config/logs/               # Audiobookshelf's own structured logs
```

## Command reference

| Command | Aliases | Purpose |
|---------|---------|---------|
| `start` (default) | `daemon` | start as daemon |
| `foreground` | `run`, `fg` | run with file-watch in terminal |
| `stop` | — | stop the daemon |
| `restart` | — | stop then start (pulls upstream by default) |
| `status` | — | is the daemon running? |
| `logs` | — | `tail -f` the daemon log |
| `check-update` | `update-check` | is an upstream update available? |
| `check-config` | `config` | validate config + print report |
| `install-service` | `install` | autostart on boot |
| `uninstall-service` | `uninstall` | remove the autostart service |
| `init-config` | `init` | write a sample `.env` |
| `rebuild-sqlite` | `rebuild-sqlite3` | force rebuild of sqlite3 native binding (Bun only) |
| `version` | `--version`, `-V` | print version |
| `help` | `--help`, `-h` | help screen |

| Flag | Effect |
|------|--------|
| `--dev` / `-d` | dev mode |
| `--prod` / `-p` | production mode (default) |
| `--update` | pull upstream changes before start |
| `--no-update` | skip the upstream pull |
| `--home` | for `init-config`: write `~/.env_abs` |
| `--debug` | enable shell xtrace (same as `ABS_DEBUG=1`) |

Full reference: `man runabs`.

## Uninstall

```sh
runabs.sh stop                    # stop the server
runabs.sh uninstall-service       # remove autostart, if installed
make uninstall                    # remove script + man page
rm -rf ~/audiobookshelf           # only if you also want to remove all data
```

(Adjust `~/audiobookshelf` if you customized `$ABS_ROOT`.)

## License

GPL-3.0-or-later. Full text is in the [`LICENSE`](LICENSE) file. The script is provided **AS IS** with no warranties; see the top of `runabs.sh` for the abbreviated notice.

Audiobookshelf itself is licensed separately by its authors. This script is independent and unaffiliated.
