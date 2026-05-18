# Security

## Is `runabs.sh` itself a security risk?

The short answer is **no, not meaningfully — but that's the wrong question.**

`runabs.sh` is a wrapper. It does not listen on the network, does not open ports, does not accept connections, does not parse network protocols. All of those things are done by Audiobookshelf itself, which is the same Node.js application whether you run it via Docker, Apple `container`, or this script. The CVE history of Audiobookshelf (XSS, SSRF, path traversal, auth bypass) applies to ABS the application, not to how you launch it.

What `runabs.sh` *does* is read configuration, validate it, write a few generated files (`dev.js`, a launchd plist, a systemd unit, or a crontab line), download and build the upstream ABS source, then spawn it.

The pieces of that flow that *could* be a security risk, and how the script handles them:

| Concern | How `runabs.sh` handles it |
|---------|----------------------------|
| Shell injection via config values reaching generated files | Every value that ends up in `dev.js`, the systemd unit, or the plist passes through `validate_string_safe_for_js_literal_and_print_errors` (rejects single quotes, double quotes, backslashes, newlines). The `dev.js` generator additionally uses a quoted heredoc + `printf` for all field insertions, so the generation is provably safe by construction. |
| Symlink / TOCTOU on temp files | All temp files use `mktemp` with an `XXXXXX` template, both in `$TMPDIR` and inside `$ABS_ROOT` (for crontab edits). No predictable `/tmp/$$` paths anywhere. |
| Accidentally deleting user data | `rm -rf $REPO_DIR` refuses to run unless the directory is empty or is recognizable as an ABS checkout (contains `.git/` or `index.js`). Pointing `ABS_ROOT` at an existing populated directory will produce an error, not silent data loss. |
| Privilege escalation | The script is designed to run as your normal user. It does not use `sudo` internally, does not write outside `$ABS_ROOT` and `$HOME` (except via `make install`, which is explicit), and refuses to behave as if it were root. Service-installation targets (launchd LaunchAgent, systemd `--user`) all run as your user, not as a system daemon. |
| Compromised download path | The script downloads nunicode binaries from `github.com` over HTTPS, and (with explicit per-run consent) runs the official Bun installer the same way. Neither is checksum-verified — the trust model is HTTPS + the upstream's release process. This is documented in the Bun consent prompt, with a pointer to package-manager alternatives for stricter setups. |
| Signal-handling races during stop | The graceful-stop window (`SIGTERM` → wait → `SIGKILL`) defers `INT`/`TERM` so a `Ctrl+C` during the stop sequence cannot leave a daemon in a half-killed state with a stale PID file. |
| Empty / malformed config values | `ABS_ROOT` and `ABS_PORT` are checked for empty values after env files are sourced (`${VAR:-default}` only catches *unset*, not *set-but-empty*). `ABS_HOST` is validated against RFC 1123 hostnames, strict IPv4, and length-checked IPv6. `ABS_PORT` is range-checked. Invalid values produce an error, not a silent fallback to something dangerous. |

If you find a way past any of those — for example, a config value that smuggles a shell metacharacter into a generated file, a path that bypasses the `$REPO_DIR` safety check, or a temp-file race — please report it (see "Reporting" below).

## Why running without Docker is the real question

The thing to think carefully about isn't `runabs.sh`. It's that **Docker (or any container runtime) provides defense-in-depth that direct execution does not**:

- **Filesystem isolation.** A Docker container only sees the paths you mount. A directly-running ABS process sees everything your user can see. If an ABS bug allows reading arbitrary files (path traversal), the impact is larger without Docker.
- **Network isolation.** A containerized ABS only sees the ports you publish. A directly-running ABS process can reach anything your machine can reach on the local network, including services bound to localhost. SSRF bugs have a wider blast radius without Docker.
- **Process isolation.** A bug in ABS that achieves code execution gets a shell inside a container with Docker; without Docker, it gets a shell in your user account, with access to your `~/.ssh`, browser cookies, etc.
- **Update model.** Docker images are versioned tags you can pin and audit. `runabs.sh` pulls from the upstream git default branch by default; you trust whatever has been merged.

None of this means "Docker = safe, direct = unsafe." Docker has its own attack surface (Docker Desktop's CVE history is non-trivial, and a misconfigured volume mount with `:rw` re-introduces filesystem reach). And direct execution has *some* advantages — a smaller dependency tree, no daemon running as root, easier auditability of what's actually executing.

The point is that the tradeoff is real and asymmetric, and the decision deserves more than five minutes of thought before you put ABS on the public internet via this script.

**The full analysis is in [`ABS_NO_DOCKER.md`](ABS_NO_DOCKER.md#internet-exposure--security)** — "Internet exposure & security" section, with a side-by-side table of which threats change between Docker/script/container and which don't, plus concrete hardening steps (reverse proxy, JWT secret, VPN-only access).

## Reporting

Bugs in `runabs.sh` or its documentation: open an issue at
<https://github.com/katertier/runabs/issues>.

Security-sensitive findings (the kind in the table above): please open a
private advisory at
<https://github.com/katertier/runabs/security/advisories/new>
rather than a public issue. That gives us a private discussion channel
and the option to coordinate disclosure if needed.

Bugs in Audiobookshelf itself (the server, web client, mobile apps, auth flows) belong upstream at
<https://github.com/advplyr/audiobookshelf/issues> — the `runabs` project does not write or maintain the server and cannot fix server bugs.

## Supported versions

Only the most recent release is supported with fixes. If you're running an older version, the first response to any report will likely be "please update and confirm the issue still reproduces."
