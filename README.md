# Janelia Mojo Sandbox

A reproducible [Podman](https://podman.io/) container that gives students a
Linux + NVIDIA GPU environment for the [Mojo](https://www.modular.com/mojo)
programming language, managed with [pixi](https://pixi.sh/), reachable from
a browser via a [ttyd](https://github.com/tsl0922/ttyd) web terminal behind
a [Caddy](https://caddyserver.com/) TLS reverse proxy. Built for a
classroom setting on Janelia's LSF/GPU cluster, reverse-proxied through
`fileglancer-dev.int.janelia.org`.

This adapts the same architecture as
[`JaneliaSciComp/marimo_ai_sandbox`](https://github.com/JaneliaSciComp/marimo_ai_sandbox)
(Podman + GPU/CDI + ttyd + Caddy + Fileglancer), stripped to only what a
Mojo classroom needs: no AI-agent CLIs, no notebook server, no Apptainer
backend, no LSF `bsub` re-entry.

## Threat model -- read this before class

**This is a convenience sandbox, not a security sandbox.** Please
understand the following before relying on it:

- Container namespaces give real process isolation, but cgroup resource
  limits (CPU/memory/PID caps) are not reliably enforced on this HPC
  without infrastructure changes this repo can't provide.
- Identity is not isolated: files written under `/work` land owned by the
  real submitting user's host uid/gid unless `--keep-id` is used
  deliberately (see below).
- **ttyd auth is a single credential shared by the entire class for a
  given launch** -- not per-student, and not revocable without relaunching
  (which rotates the credential for everyone). Anyone who has the URL or
  QR code -- or can screenshot/photograph a projected one -- has the exact
  same shell access as every other student. There is no way to attribute
  an action inside the sandbox to a specific student.
- No network-egress restriction is applied by default -- students have
  normal outbound network access from inside the container.
- The container runs with `--net=host` (shares the host's network
  namespace entirely, not an isolated container network) -- this is
  required so ttyd, bound inside the container, is directly reachable on
  the host's own network stack for Caddy (or Fileglancer's own proxy) to
  reverse-proxy to. It also means there is no network-level separation
  between the container and the host it's running on.

Accept this consciously for a classroom setting; it is not something to
discover later.

## Usage

**Instructor (shared classroom session):**

```bash
pixi run terminal -- --work /scratch/$USER/mojo-work --keep-id
```

`--keep-id` requires a provisioned `/etc/subuid`/`/etc/subgid` range for
your account (ask Janelia HPC if you don't have one) -- it makes files
under the shared work directory land owned by your real host account
instead of root-mapped-through-the-user-namespace. This is the instructor's
choice to make; **students launching their own instance should normally
leave `--keep-id` off**, since most student accounts have no subuid range.

Once it starts, the job log prints an ASCII QR code (and saves
`$WORK/qrcode.png`) encoding the full login URL
(`https://classroom:<token>@<host>:<port>/`) -- project it or share it with
the class. Everyone who scans it or opens the URL lands in the same shared
terminal session, no separate login step.

**A student launching their own isolated instance** (no auth conflict,
fully separate container/job from the shared one):

```bash
pixi run terminal -- --work /scratch/$USER/my-own-mojo-work
```

**Plain interactive shell** (no ttyd/Caddy, e.g. for local testing):

```bash
pixi run shell -- --work /scratch/$USER/mojo-work
```

**Plain HTTP** (no Caddy/TLS of our own -- for testing against
Fileglancer's own HTTPS-wrapping of a plain-HTTP service, instead of this
repo's self-managed Caddy + self-signed cert):

```bash
pixi run terminal-http -- --work /scratch/$USER/mojo-work
```

Only use this where the hop between the job and whatever terminates TLS
for it (e.g. Fileglancer's proxy) is trusted -- the traffic on that hop is
unencrypted. Same shared "classroom" login model as `pixi run terminal`
above.

**First connection**: your browser will warn about the self-signed TLS
certificate (`terminal-wrap.sh` generates and reuses one, since Caddy's own
internal-CA issuer hangs waiting for an interactive `sudo` session on a
compute node). Accept/proceed past the warning -- see Caddy's docs or your
browser's "Advanced -> Proceed" flow. The cert's path is printed at
startup if you'd rather install it in your trust store.

**Using a trusted cert instead, when available:** if the
[`pca`](https://github.com/JaneliaSciComp/personal-certificate-authority)
CLI is on `PATH` (and `pca init` has been run once), `caddy_generate_cert`
prefers a `pca`-issued certificate over generating its own self-signed one --
no flag or config needed, it's detected automatically. A `pca`-issued cert
is signed by a CA that's actually installed in your trust store, so there's
no browser warning to click through for the class to deal with. If `pca`
isn't installed, or hasn't been initialized yet, this falls straight back
to the self-signed cert above with no error -- purely an opportunistic
upgrade, not a new requirement.

## Mojo environment

The Mojo/MAX toolchain is **not** baked into the container image. It's
seeded into `/work/app` (from `container/app/pixi.toml`) on first launch of
a given `--work` directory, and (re-)installed via `pixi install` on
*every* launch -- so editing `/work/app/pixi.toml` (e.g. `pixi add <package>`
from inside the sandbox) takes effect on the next shell/terminal launch
without rebuilding the image.

```bash
mojo run app/hello.mojo
mojo build app/hello.mojo && ./hello
```

## Layout

```
pixi.toml                     image-baked infra tools (git, jq, vim, nano, ttyd, python)
                               + [feature.https] caddy, openssl, qrcode/pillow (HOST-side only)
container/
    common.sh                 shared flag/env parsing, GPU detection, autofs-parent guard
    caddy-lib.sh               self-signed cert / Caddy / service-URL-publish helpers
    entrypoint.sh               baked ENTRYPOINT: seeds /work/app, `pixi install`, exec "$@"
    terminal-wrap.sh            ttyd + Caddy TLS + QR code wrapper (self-managed TLS)
    terminal-http.sh             plain-HTTP ttyd wrapper, no TLS of our own
                                  (for Fileglancer's own HTTPS-wrapping)
    app/pixi.toml                seeded into /work/app: mojo/MAX dependency
    app/hello.mojo                starter example
    podman/Containerfile          Ubuntu 24.04 + pixi + clang/lld + ttyd runtime deps
    podman/lib.sh                  storage isolation / catatonit watchdog
    podman/build.sh                 podman build wrapper
    podman/shell.sh                  interactive shell / ttyd command-override launcher
runnables.yaml                Fileglancer job manifest
```

## GPU passthrough

`common.sh` detects a GPU at launch time via `nvidia-smi -L` and passes
`--device nvidia.com/gpu=all` (NVIDIA CDI) automatically -- no flag needed,
and no harm on a non-GPU node.

## Known limitations / open items for Janelia HPC & Fileglancer admins

- Whether the LSF GPU queue/resource request (e.g. a specific `-q`) is
  something Fileglancer's own job submission handles for this manifest --
  nothing in this repo's scripts requests a GPU-capable queue directly.
  Confirm before classroom rollout.
- Whether `fileglancer-dev.int.janelia.org` trusts self-signed
  published-service certs the same way the production instance does.
- `--keep-id` requires a provisioned subuid/subgid range; confirm which
  accounts (instructor, any TAs) have one.
- The LSF `bsub` re-entry wrapper and the network-egress allowlist from
  `marimo_ai_sandbox` are intentionally not included here -- `bsub` +
  rootless Podman is confirmed broken on this cluster (Kerberos `eauth`
  fails inside the user namespace), and there's no egress-restriction
  requirement yet. Both exist verbatim in that repo if ever wanted later.
