# TODO -- pick up on the Janelia LSF cluster

This repo was designed and implemented from a macOS machine, which cannot
run Podman, access an NVIDIA GPU, or reach the real LSF/Fileglancer
environment. Everything below still needs to be verified live on a Janelia
HPC node. Nothing here has been build-tested or run-tested yet -- only
`bash -n` syntax checks, `pixi lock` (both `pixi.toml` and
`container/app/pixi.toml` resolved cleanly for `linux-64`), and YAML
validation have been done so far.

Full design rationale lives in `README.md` (read the threat-model section
first) and in the original plan file this repo was built from
(`~/.claude/plans/i-need-to-setup-rippling-cookie.md` on the machine that
authored it, if still available -- otherwise this TODO plus the README
should be self-sufficient).

## 1. Build

```bash
pixi install          # materializes the top-level (host-side) pixi env
pixi run build         # -> podman build via container/podman/build.sh
```

Watch for:
- The `APT::Sandbox::User "root"` / `TAR_OPTIONS=--no-same-owner`
  workarounds in `container/podman/Containerfile` actually being necessary
  (they address a missing `/etc/subuid` range on this cluster) -- if the
  build account *does* have a subuid range, confirm the build still
  succeeds either way.
- `clang`/`lld`/`libc6-dev` installing cleanly from Ubuntu 24.04's repos.
- `pixi install --locked` inside the Containerfile succeeding against the
  committed `pixi.lock` (don't let it silently re-resolve).

## 2. Interactive shell smoke test

```bash
pixi run shell -- --work /scratch/$USER/mojo-work --keep-id
```

(Instructor use, exercising `--keep-id` -- requires a provisioned
`/etc/subuid`/`/etc/subgid` range for your account; drop `--keep-id` to
also validate the default student-launch path.)

Inside the container, check in order:
- [ ] `nvidia-smi` sees the GPU (validates CDI `--device nvidia.com/gpu=all`
      wiring + `HAS_GPU` detection in `container/common.sh`)
- [ ] `clang --version` reports LLVM/clang
- [ ] `mojo --version` resolves from `/work/app/.pixi/envs/default/bin`,
      **not** the image's own baked pixi env at `/opt/app/.pixi/envs/default`
      (validates `container/entrypoint.sh`'s seeding + `PATH` ordering)
- [ ] `mojo run app/hello.mojo` prints `Hello world`
- [ ] `mojo build app/hello.mojo && ./hello` produces and runs a compiled
      native binary -- this specifically exercises the clang/lld linker
      path that `mojo run` alone does not touch
- [ ] `vim` and `nano` both launch and can save a file under `/work`

Then:
- [ ] **Re-launch idempotency**: exit, re-run the same `--work` dir,
      confirm `app/pixi.toml` is NOT re-seeded (`cp -n` in `entrypoint.sh`)
      but `pixi install` still runs (should be a fast no-op) -- validates
      "seed once, install every launch."

## 3. Full HTTPS (self-managed TLS) path, from a browser

```bash
pixi run terminal -- --work /scratch/$USER/mojo-work --keep-id
```

- [ ] Confirm a published `https://classroom:<token>@<host>:<port>/` URL,
      an ASCII QR code printed to the job log, and `qrcode.png` written
      under `$WORK`.
- [ ] Scan the QR (or open the URL) from a separate machine/phone on the
      Janelia network; accept the self-signed cert warning; confirm the
      terminal loads with the embedded credential auto-authenticating (no
      manual login prompt).
- [ ] Confirm opening the bare `https://<host>:<port>/` URL **without** the
      credential correctly prompts for HTTP Basic auth (i.e. auth is
      actually enforced, not decorative).
- [ ] Repeat the `mojo run` / `mojo build` checks from step 2 through the
      browser terminal.
- [ ] Close the tab, confirm `terminal-wrap.sh`'s cleanup trap tears down
      both `ttyd` and `caddy` -- check for an orphaned `catatonit -P`
      process afterward (this is the specific failure mode that has
      previously left real Fileglancer jobs stuck in LSF's RUN state
      forever on this cluster; `container/podman/lib.sh`'s
      `podman_storage_cleanup` is supposed to prevent it).

## 4. Plain-HTTP path (for testing Fileglancer's new HTTPS-wrapping)

```bash
pixi run terminal-http -- --work /scratch/$USER/mojo-work-http
```

This is new/untested relative to the original design -- added specifically
to test against Fileglancer's own HTTPS-wrapping of a plain-HTTP backend,
instead of this repo's self-managed Caddy+cert path.

- [ ] Confirm `ttyd` comes up on plain HTTP (`0.0.0.0:$PORT`, default port
      7681) with the shared `classroom:<token>` Basic Auth still enforced.
- [ ] Register this as a Fileglancer runnable (`mojo-terminal-http` in
      `runnables.yaml`) and confirm Fileglancer's HTTPS-wrapping actually
      reaches it and terminates TLS correctly end-to-end -- **this is the
      main open question this variant exists to answer.**
- [ ] Confirm the shared token file (`$WORK/.classroom-token`) is
      compatible between this variant and the HTTPS variant (same file,
      same format) if a `--work` dir is ever used with both.

## 5. Multi-instance isolation

- [ ] Launch two different `--work` dirs concurrently on the same GPU
      node (e.g. one HTTPS, one plain-HTTP, or two shells); confirm
      `podman_storage_setup_job`'s per-job `--root`/`--runroot` keying
      (keyed off `$LSB_JOBID`) prevents storage collisions between them --
      validates the "student can launch their own isolated instance"
      requirement.

## 6. Fileglancer registration

- [ ] Register `runnables.yaml` with `fileglancer-dev.int.janelia.org`
      (the **dev** instance, not prod) and confirm both runnables
      (`mojo-terminal-https`, `mojo-terminal-http`) show up and launch
      correctly through Fileglancer's own job-submission UI, not just via
      direct `pixi run` on a login/compute node.

## 7. Confirm with Janelia HPC / Fileglancer admins before classroom rollout

- [ ] Whether the instructor account (and any TAs) has a provisioned
      `/etc/subuid`/`/etc/subgid` range -- required for `--keep-id` to do
      anything at all.
- [ ] The correct LSF GPU-queue/resource-request syntax Fileglancer uses
      for this manifest (nothing in `runnables.yaml` or the scripts
      requests a GPU-capable queue directly -- GPU is auto-detected at
      container-launch time via `nvidia-smi -L`, not requested through
      Fileglancer/LSF resource syntax).
- [ ] Whether `fileglancer-dev.int.janelia.org` handles self-signed
      published-service certs the same way prod does (relevant to the
      HTTPS variant's browser-trust UX).
- [ ] Whether Fileglancer's HTTPS-wrapping feature (the reason
      `terminal-http.sh` exists) is stable enough to prefer over the
      self-managed Caddy path long-term, or whether both should stay
      available as alternatives.

## Known, deliberate limitations (do not "fix" without discussion)

- No per-student auth -- one shared `classroom:<token>` credential per
  launch, by design (see README threat model).
- No Apptainer backend, no `bsub` re-entry wrapper, no network-egress
  allowlist -- all explicitly out of scope for v1 (see README's "Known
  limitations" section for why).
- Container runs with `--net=host` -- required for ttyd to be reachable
  from the host-side Caddy/Fileglancer proxy; not a mistake.
