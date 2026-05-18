# Running Audiobookshelf in Apple's `container` (no Docker required)

A guide to running Audiobookshelf on Apple Silicon Macs using Apple's own
[`container`](https://github.com/apple/container) CLI — the native Linux-container
runtime Apple shipped in 2025. It's a third option alongside
[`runabs.sh`](./ABS_NO_DOCKER.md) (direct execution) and Docker Desktop / OrbStack.

If you've read the main [guide](./ABS_NO_DOCKER.md) and decided you want containerized
isolation but don't want Docker Desktop's heavyweight VM, this is for you.

---

## Table of contents

1. [What is Apple's `container`?](#what-is-apples-container)
2. [Prerequisites](#prerequisites)
3. [Install](#install)
4. [Start the container runtime](#start-the-container-runtime)
5. [Run Audiobookshelf](#run-audiobookshelf)
6. [Lifecycle: stop / start / logs / update](#lifecycle-stop--start--logs--update)
7. [Networking caveats](#networking-caveats)
8. [Autostart at login](#autostart-at-login)
9. [Comparison: `container` vs. Docker Desktop](#comparison-container-vs-docker-desktop)
10. [Comparison: `container` vs. runabs.sh (direct)](#comparison-container-vs-runabssh-direct)
11. [When to choose which](#when-to-choose-which)
12. [Troubleshooting](#troubleshooting)

---

## What is Apple's `container`?

`container` is an Apple-developed, open-source command-line tool that runs Linux
containers on macOS using Apple's own Virtualization framework. Two things make it
distinctive:

- **Each container gets its own micro-VM.** Docker Desktop runs all your containers
  inside a single shared Linux VM. `container` boots a dedicated lightweight VM
  per container. The kernel comes from the Kata Containers project (Apple isn't
  reinventing the kernel).
- **OCI-compatible.** It pulls and runs the same images you'd use with Docker. Same
  `ghcr.io/advplyr/audiobookshelf:latest` image, same `/audiobooks` and `/config`
  volume conventions.

Practical consequences:

- **Stronger isolation.** A kernel exploit in one container doesn't reach other
  containers; each VM is its own boundary.
- **Sub-second startup.** Per-VM cold start is well under a second.
- **No always-running VM.** When no containers are running, no system resources
  are consumed. Docker Desktop's VM idles whether you're using it or not.
- **No license, no Docker Inc. dependency.** It's Apple software, Apache-2.0.

It is not a complete Docker replacement yet — see [Comparison](#comparison-container-vs-docker-desktop).

## Prerequisites

| Requirement | Notes |
|---|---|
| Apple Silicon Mac (M1 / M2 / M3 / M4) | x86_64 Macs are unsupported. |
| macOS 26 (Tahoe) or macOS 15 (Sequoia) | macOS 26 is fully supported; macOS 15 works with networking limitations. |
| Homebrew (recommended) | Or download the signed `.pkg` from the [GitHub releases page](https://github.com/apple/container/releases). |
| `ffmpeg`, `git`, etc. | **Not needed on the host.** The ABS container image bundles everything. This is the main convenience over `runabs.sh`. |

You do **not** need:

- Docker Desktop
- Node.js, Bun, npm, git, ffmpeg, or any of the runabs.sh prerequisites
- Rosetta 2 (the ABS image is multi-arch and includes arm64 native binaries)
- A separate Linux VM

> ✓ **Apple Silicon ffmpeg note:** the Apple-Silicon-x86_64-ffmpeg problem that affects `runabs.sh` direct execution **does not affect this path**. The official ABS image is multi-arch (`linux/amd64` + `linux/arm64`); on Apple Silicon Macs, `container` pulls the `linux/arm64` variant, which has arm64 ffmpeg pre-installed via Alpine's package manager. ABS's BinaryManager finds it on PATH and never triggers the downloader.

## Install

### Homebrew (recommended)

```sh
brew install container
container --version
```

### Direct download

```sh
curl -LO https://github.com/apple/container/releases/latest/download/container-installer-signed.pkg
sudo installer -pkg container-installer-signed.pkg -target /
container --version
```

## Start the container runtime

`container` uses a background daemon (`container-apiserver`). Start it once after
installing, and after each reboot if you haven't set up autostart yet:

```sh
container system start
```

The first time you run this, it'll prompt you to download a Linux kernel
(via Kata Containers, ~50 MB). Accept the default:

```
No default kernel configured. Install the recommended default kernel from
[https://github.com/kata-containers/.../kata-static-3.17.0-arm64.tar.xz]? [Y/n]: y
```

Verify the daemon is running:

```sh
container system status
container list -a
```

To stop the runtime (e.g. before a reboot you want to be clean about):

```sh
container system stop
```

## Run Audiobookshelf

### One-shot `container run`

The minimum to get ABS running. Create the data directories first so volume mounts
don't end up as root-owned root-empty dirs:

```sh
mkdir -p ~/audiobookshelf/{config,metadata,audiobooks,podcasts}

container run -d \
  --name audiobookshelf \
  --publish 13378:80 \
  --volume ~/audiobookshelf/config:/config \
  --volume ~/audiobookshelf/metadata:/metadata \
  --volume ~/audiobookshelf/audiobooks:/audiobooks \
  --volume ~/audiobookshelf/podcasts:/podcasts \
  --env TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')" \
  ghcr.io/advplyr/audiobookshelf:latest
```

The `TZ=` expression reads your Mac's current timezone from `/etc/localtime`
(no `sudo` required, unlike `systemsetup -gettimezone`) and passes it to the
container. If you'd rather pin it explicitly, replace it with e.g.
`TZ=America/Los_Angeles`.

> ⚠️ **Flag order matters.** All flags must come **before** the image name. The
> CLI passes anything after the image as command arguments to the container,
> not as flags to `container run`. This is different from Docker, where the
> argument parser is more forgiving.

After it starts, ABS is reachable at <http://localhost:13378>.

### Using `container compose` (recommended for ongoing use)

`container` supports a subset of `docker compose` syntax. Create
`~/audiobookshelf/compose.yml`:

```yaml
services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    ports:
      - "13378:80"
    volumes:
      - ./config:/config
      - ./metadata:/metadata
      - ./audiobooks:/audiobooks
      - ./podcasts:/podcasts
    environment:
      - TZ=${TZ:-UTC}
```

Then alongside it, create `~/audiobookshelf/.env`. Compose reads this file
automatically and uses its values to interpolate `${TZ}` etc. in the YAML
above. You can generate it once and commit nothing host-specific to source
control:

```sh
cd ~/audiobookshelf
cat > .env <<EOF
# Auto-generated by setup. Edit if your machine values change.
TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
EOF
```

Then:

```sh
container compose up -d
```

This is the easier path long-term: configuration lives in version-controllable
YAML next to your data, with host-specific values isolated in `.env`.

> **Note on `UID`/`GID`:** It's tempting to write `PUID=${UID}` in the
> compose file, but Compose-spec interpolation reads from the **exported**
> environment, and `UID`/`GID` are bash shell variables that aren't exported
> by default. They'd resolve to empty. If you need PUID/PGID (see the
> [volume mounts troubleshooting](#volume-mounts-are-read-only-or-owned-by-root)
> section), either:
>
> - Add them to `.env` explicitly: `printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> .env`, or
> - Export before running: `PUID=$(id -u) PGID=$(id -g) container compose up -d`
>
> Note that the **official `ghcr.io/advplyr/audiobookshelf` image doesn't
> honor `PUID`/`PGID`**, so this only matters if you switch to a fork that
> does (e.g. the linuxserver-style `ddsderek/audiobookshelf`).

## Lifecycle: stop / start / logs / update

```sh
# Status
container list                          # only running
container list -a                       # all, including stopped
container inspect audiobookshelf        # full JSON

# Logs
container logs -f audiobookshelf        # tail -f equivalent

# Stop / start / restart
container stop audiobookshelf
container start audiobookshelf
container restart audiobookshelf        # if supported in your version

# Update (pull a newer image, then re-create)
container pull ghcr.io/advplyr/audiobookshelf:latest
container stop audiobookshelf
container rm audiobookshelf
# ...then run the `container run -d ...` command above again,
# or:  container compose up -d --force-recreate

# Tear down completely (containers only; data on disk stays)
container stop audiobookshelf
container rm audiobookshelf
container images rm ghcr.io/advplyr/audiobookshelf:latest   # optional
```

The `compose` workflow is shorter:

```sh
cd ~/audiobookshelf
container compose down       # stop + remove
container compose pull       # fetch latest image
container compose up -d      # recreate from new image
```

## Networking caveats

This is the area where `container` diverges from Docker most visibly, and where
behavior differs between macOS 15 and macOS 26.

### macOS 26 (Tahoe) — what you'd hope for

Each container gets its own IP address on a local virtual network. You can:

- Reach ABS via `http://localhost:13378` (the published port) **or**
- Reach it directly at the container's IP (find it via `container list`) on
  port 80, without any port publishing at all.
- Container-to-container traffic works on the same virtual network.

### macOS 15 (Sequoia) — known rough spots

Apple shipped `container` with macOS 15 support, but networking is incomplete:

- Containers on the same virtual network sometimes can't see each other.
- Some containers launch without an IP address.
- DNS resolution can drop.

For a single-container Audiobookshelf setup with only `--publish 13378:80`, this
usually works fine — the published port works through host networking. But you
might hit weirdness if you later add a reverse-proxy container or a database
container. If you're on macOS 15, expect to occasionally `container restart`
when networking acts up.

### macOS firewall

On a fresh install, macOS's application firewall may block the
`container-apiserver` from accepting connections. If `localhost:13378` doesn't
work after `container run`, check
`System Settings → Network → Firewall` and allow the `container-apiserver`
process.

### LAN access

To reach ABS from your phone or other devices on the LAN:

- The `--publish 13378:80` flag exposes the port on the Mac's IP, just like Docker.
- Find your Mac's IP (`ipconfig getifaddr en0`) and visit
  `http://<mac-ip>:13378` from another device.
- Per-container IPs (macOS 26) aren't reachable from outside the Mac — they're
  on an internal virtual network.

## Autostart at login

`container` does **not** yet have a `--restart=always` equivalent or built-in
boot-time autostart. Two GitHub issues track this
([#158](https://github.com/apple/container/issues/158) for system-boot autostart,
[#286](https://github.com/apple/container/issues/286) for per-container restart
policies); neither is implemented as of this writing.

Until those land, use a launchd user agent that starts the runtime and the
container at login.

Create `~/Library/LaunchAgents/org.audiobookshelf.container.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>org.audiobookshelf.container</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/opt/homebrew/bin/container system start &amp;&amp; /opt/homebrew/bin/container start audiobookshelf || /opt/homebrew/bin/container compose -f $HOME/audiobookshelf/compose.yml up -d</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/audiobookshelf-container.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/audiobookshelf-container.log</string>
</dict>
</plist>
```

Adjust the `container` path if you didn't install via Homebrew. The `$HOME`
reference inside the `compose -f` argument is expanded by `/bin/sh -c`
(launchd invokes that on the line above), not by launchd itself — launchd
does not perform variable substitution on plist string values. If you ever
adapt this plist to invoke the binary directly without `/bin/sh -c`, you'll
need to hardcode the absolute path instead of using `$HOME`.

Then load it:

```sh
launchctl load ~/Library/LaunchAgents/org.audiobookshelf.container.plist
```

To remove:

```sh
launchctl unload ~/Library/LaunchAgents/org.audiobookshelf.container.plist
rm ~/Library/LaunchAgents/org.audiobookshelf.container.plist
```

Limitations of this workaround:

- It runs **at user login**, not at system boot. If you want it before login,
  you'd need a `LaunchDaemon` in `/Library/LaunchDaemons` running as root,
  which is more invasive and not recommended for a hobby setup.
- If the container crashes mid-session, it won't auto-restart. You'd need to
  add a separate watchdog script for that, or wait for issue #286 to land.

## Comparison: `container` vs. Docker Desktop

|  | Apple `container` | Docker Desktop |
|---|---|---|
| **Apple Silicon** | Native | Native (via Linux VM) |
| **VM architecture** | One micro-VM per container | One shared VM for all containers |
| **Startup overhead** | Sub-second per container; idle when nothing runs | Persistent ~1–2 GB RAM VM, always on |
| **Image format** | OCI (same as Docker) | OCI |
| **`docker compose`** | `container compose` (subset, evolving) | Full `docker compose` |
| **License / cost** | Apache 2.0 (free) | Free for personal & small business; paid for >250-employee orgs |
| **Restart policy / autostart** | ❌ Not yet (issues #158, #286) | ✓ `--restart=always`, `unless-stopped`, etc. |
| **Multi-arch image builds** | Limited (no `buildx` parity) | Full |
| **Network: same-host LAN reach** | Per-container IPs (macOS 26) or `--publish` | `--publish` or host networking |
| **macOS firewall friction** | Occasionally blocks the apiserver | Handled by Docker Desktop installer |
| **macOS 15 stability** | Known networking gaps | Production-grade |
| **macOS 26 stability** | Targeted GA platform; improving fast | Production-grade |
| **Resource controls (CPU/RAM cap)** | Per-VM (per-container) | Per-container (cgroup) |
| **Kubernetes / `kind` / Minikube** | Not yet integrated | Mature |

**Bottom line:** for **just running Audiobookshelf**, `container` is fully
adequate on macOS 26, slightly rougher on macOS 15. For complex multi-container
or Kubernetes setups, Docker Desktop is still more polished.

## Comparison: `container` vs. runabs.sh (direct)

|  | Apple `container` | `runabs.sh` (direct execution) |
|---|---|---|
| **Where ABS runs** | In a Linux micro-VM | Directly on macOS |
| **Apple Silicon ffmpeg trouble** | None (bundled in image) | You must install `ffmpeg` natively (Homebrew/MacPorts) |
| **Prerequisites on host** | Just `container` itself | git, node/bun, ffmpeg, ffprobe, etc. |
| **File access** | Bind mounts (slight overhead) | Direct, native filesystem |
| **Library scan speed** | Marginally slower (cross-VM I/O) | Fastest possible |
| **First-run setup** | ~120 MB image pull, sub-second start | 2–3 min clone + npm install + client build |
| **Updates** | `container pull` + recreate (~30 s) | `runabs.sh restart` (git pull + maybe deps) |
| **Filesystem blast radius** | Container sees only mounted volumes | ABS sees everything your user can read |
| **Network blast radius** | Container's virtual network | Host LAN + host loopback |
| **Memory overhead** | ~150–300 MB per container VM | ~100–200 MB (node/bun process) |
| **Autostart** | Launchd workaround (no built-in) | Built into `runabs.sh install-service` (launchd plist) |
| **Server logs** | `container logs` (Docker-style) | Plain log file at `$ABS_ROOT/audiobookshelf.log` |
| **Hacking on ABS source** | Painful (would need to rebuild image) | Easy (it's a git checkout in `$ABS_ROOT/audiobookshelf`) |

## When to choose which

```
What matters most to you?
│
├── "Minimum prerequisites; just give me ABS running."
│   → Apple container (one tool, image bundles everything)
│
├── "Fastest possible filesystem access for my huge library."
│   → runabs.sh direct (no VM boundary)
│
├── "Strongest sandboxing in case ABS gets compromised."
│   → Apple container (per-container VM > namespace isolation)
│
├── "I want to hack on the ABS source / try the React client / etc."
│   → runabs.sh direct (it's just a git checkout)
│
├── "I need Docker Desktop anyway for other things."
│   → Stick with Docker; no reason to add a second runtime
│
├── "macOS 15 (not Tahoe) and I want minimal moving parts."
│   → runabs.sh direct (Apple container's networking gaps don't matter to you)
│
└── "macOS 26+ and I want containerization without Docker Desktop."
    → Apple container (the original use case)
```

A reasonable rule of thumb:

- **Privacy / sandboxing-oriented user, macOS 26+:** Apple container.
- **Tinkerer who wants to read/modify ABS source:** `runabs.sh` direct.
- **"I already use Docker for ten other things":** Docker Desktop.
- **Anyone running ABS exposed to the internet:** see the
  [Internet exposure & security](./ABS_NO_DOCKER.md#internet-exposure--security)
  section of the main README; the container vs. direct choice matters less
  than your reverse proxy and patching discipline.

## Troubleshooting

### `container: command not found`

Homebrew install didn't finish, or `$(brew --prefix)/bin` isn't in your PATH.
Try `brew install container` again, and verify with:

```sh
which container
/opt/homebrew/bin/container --version
```

### `container system start` hangs or fails

The first run downloads a kernel. If it gets stuck, you can pre-download manually
and point `container` at it, but the easier fix is usually to confirm internet
connectivity and try again:

```sh
container system stop
container system start
```

### "Connection refused" on `localhost:13378`

Three usual causes:

1. **macOS firewall blocks the apiserver.** Open
   `System Settings → Network → Firewall` and allow `container-apiserver`.
2. **Container isn't actually running.** `container list -a` shows its state.
3. **You're on macOS 15 and networking is acting up.** `container restart audiobookshelf`.

### Volume mounts are read-only or owned by root

Apple's bind mounts run with the container's UID, which defaults to root inside
the ABS image. If you need files to be owned by your macOS user after the
container writes them, set `PUID`/`PGID` environment variables in the run/compose
command. Generate them dynamically with `id -u` / `id -g`:

```yaml
environment:
  - TZ=${TZ:-UTC}
  - PUID=${PUID:-501}    # injected by .env or env override
  - PGID=${PGID:-20}     # injected by .env or env override
```

Then in `~/audiobookshelf/.env` (or via shell export before `container compose up`):

```sh
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> .env
```

This works with the [`ddsderek/audiobookshelf`](https://hub.docker.com/r/ddsderek/audiobookshelf)
fork and some other community builds, but **not** with the official
`ghcr.io/advplyr/audiobookshelf` image which doesn't honor `PUID`/`PGID`. With
the official image, files will be root-owned in your bind-mounted directories.
For an audiobook library you only ever read through ABS, that's fine; if you
shuffle files in and out manually with Finder, you'll need to `chown` them or
switch to a `PUID`-aware image.

### Timezone alternative: bind-mount the host's `/etc/localtime`

Instead of setting `TZ=...` and keeping it in sync with macOS, you can let the
container read the host's `/etc/localtime` directly:

```yaml
volumes:
  - /etc/localtime:/etc/localtime:ro
  - ./config:/config
  - ./metadata:/metadata
  # ... etc
```

When macOS's timezone changes (DST, you travel, you change `System Settings →
General → Date & Time`), the container picks it up at next start with no
config edit. `:ro` makes the mount read-only as a safety measure.

> Caveat: on macOS, `/etc/localtime` is a symlink to something under
> `/var/db/timezone/zoneinfo/`. OCI bind mounts follow symlinks at mount time,
> so this works the same as on Linux. If you hit a mount-time error claiming
> the path isn't found, fall back to the explicit `TZ=` env-var approach
> above.

### Container disappears after `compose down`

`compose down` removes containers but keeps volumes mapped as bind mounts (your
data on disk is untouched). To remove the image as well:

```sh
container compose down
container images rm ghcr.io/advplyr/audiobookshelf:latest
```

### "Operation not permitted" mounting a directory under `/Users/<you>`

macOS Full Disk Access. The `container-apiserver` process needs access to the
folder you're trying to bind-mount. In
`System Settings → Privacy & Security → Full Disk Access`, add
`container-apiserver` (you may need to click the lock and authenticate). Then
`container system stop && container system start`.

### Where did my data go after I removed the container?

It's where you bind-mounted it. The container is ephemeral; the
`~/audiobookshelf/{config,metadata,audiobooks,podcasts}` directories on your
Mac are not. To migrate to a different setup (Docker Desktop, runabs.sh, etc.),
point that setup at the same directories.

---

## See also

- [Main guide: running ABS without Docker](./ABS_NO_DOCKER.md) — overview, runabs.sh direct execution, security considerations
- [`man runabs`](./runabs.1) — full reference for the direct-execution script
- [Apple container source & releases](https://github.com/apple/container)
- [Apple container documentation](https://apple.github.io/container/)
- [Audiobookshelf Docker docs](https://www.audiobookshelf.org/docs/)
