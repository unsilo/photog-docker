# Release checklist — v0.1.0

Internal. Not part of what users need. This is the list of things that are
**claimed** in this repository and not yet **true**.

Nothing in this repo has been tested against a running image, because the image
has never been built.

---

## Blocking — the repo is wrong until these are done

### 1. The default branch must be `main`

`install.sh` and every `curl` line in the README fetch from
`raw.githubusercontent.com/unsilo/photog-docker/main/...`. The local repo is on
`bootstrap` with no commits.

```bash
git branch -m bootstrap main
git push -u origin main
```

Or change `PHOTOG_REF`/`RAW` in `install.sh` and every raw URL in the docs. The
branch is the cheaper fix.

### 2. Registry name

`deploy/docker/build-and-push.sh` in the photog repo pushes to
**`tehsnappysoftware/photog`**. `deploy/docker/docker-compose.rpi5.yml` in that
same repo still pulls **`tehsnappysoftware/pho_tog`** — an underscore, a
different repository, and nothing would ever pull.

This repo standardises on `tehsnappysoftware/photog`. Delete or fix the stale
compose files (see §7).

### 3. Architecture — decided: arm64 only for 0.1.0

**Settled.** `build-and-push.sh`'s `PLATFORMS=linux/arm64` default stands, and
the docs now say so rather than implying x86 works:

- `README.md` has an "arm64 only, for now" section listing what is and is not
  covered, with the emulation escape hatch
- `install.sh` refuses to run on `x86_64` with an explanation, unless
  `ALLOW_EMULATION=1`
- `docs/troubleshooting.md` has entries for `no matching manifest for
  linux/amd64` and `exec format error`

Cross-building amd64 on the M1 goes through QEMU and costs hours per attempt,
mostly in EXLA. Not worth paying on a first release to serve a platform nobody
has asked for yet.

**amd64 comes from GitHub, not from your laptop.** A workflow is written and
waiting at `.github/workflows/publish.yml` in the *photog* repo — see §3a. When
it has run green once, delete the arm64-only section from the README, drop the
`x86_64` branch in `install.sh`, and republish.

### 3a. The GitHub Actions publish workflow — never run

`~/projects/photog/.github/workflows/publish.yml`. Builds each architecture on
its own native runner (`ubuntu-24.04-arm` and `ubuntu-latest`), pushes them by
digest, assembles one multi-arch manifest, then boots the result against a real
Postgres and asserts it serves a page and seeds the admin account.

`ubuntu-24.04-arm` became available in private repositories in January 2026 and
counts against the plan's included minutes. It is **2 vCPUs** in a private repo
against 4 in a public one, so the arm64 leg is the slow half — the GHA layer
cache (`type=gha`, scoped per architecture) is what makes the second run
tolerable.

Before it can work:

- [ ] add repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a
      Docker Hub personal access token with Read & Write, not your password)
- [ ] run it once from the Actions tab with **`arm64 only`** and a throwaway
      version like `0.1.0-rc1`, so a failure does not touch `:latest`
- [ ] then run `both` for the real `0.1.0`

It has passed `actionlint` and nothing else. It has never executed. Expect the
first run to fail on something small — a runner label, a missing secret, a build
arg — rather than on anything structural.

Note it publishes from the private repo, which is correct: the build context is
`web/`, and only that repo has it.

### 4. Build and push

Locally, which is the path that has to work first — the workflow in §3a is an
optimisation, not a prerequisite:

```bash
cd ~/projects/photog
./deploy/docker/build-and-push.sh 0.1.0
```

Tags `:0.1.0` and `:latest`, arm64, native on the M1. First build is long — XLA
downloads a large precompiled archive, Snex resolves a Python toolchain through
`uv`.

Before pushing anything, smoke-test locally:

```bash
docker buildx build --platform linux/arm64 -f deploy/docker/Dockerfile.web \
  -t photog:test --load web/
```

### 5. Actually run the quick start

On a clean machine — a fresh Pi, or a VM. Not the Mac you built on.

```bash
curl -fsSL https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh | bash
```

Then confirm, in order:

- [ ] `docker compose ps` shows all three services, `photog` healthy
- [ ] `http://<host>` loads the login page
- [ ] the seeded admin can log in
- [ ] a photo dropped in `~/photog/import` imports
- [ ] its thumbnail renders (this is the `PHOTOG_IMAGE_URL_BASE` check)
- [ ] the gallery is interactive — sorting, tagging (this is the
      `check_origin` check)
- [ ] `docker compose down && docker compose up -d` keeps the photo
- [ ] `docker compose pull && up -d` does not break (the nginx `resolver` check)

Every one of those is a distinct failure mode described in the docs. Any that
fails means a doc page is describing a fix that does not work.

### 6. Docker Hub repository

- [ ] create `tehsnappysoftware/photog`, public
- [ ] short description: "Self-hosted photo archive for Raspberry Pi and Linux"
- [ ] full description: point at
      `https://github.com/unsilo/photog-docker` and paste the quick start
- [ ] link the EULA — the licence requires it to be visible where the image is
      distributed, not only inside it

`build-and-push.sh` does not push a description; do it in the web UI or with
`docker pushrm`.

---

## Should do, would embarrass you if someone noticed

### 7. Retire the superseded files in the photog repo

`deploy/docker/` now has two jobs mixed together. Keep the build side, delete
the runtime side — it is what this repo is for, and the copies there describe
an architecture that no longer exists.

Keep:

- `Dockerfile.web`
- `build-and-push.sh`

Delete or rewrite:

| File | Why |
|---|---|
| `README.md` | Describes three images selected by `--build-arg HAILO`, `MIX_TARGET=rpi5`, `:nx_hailo` and `c_src/hailo8.cpp`. All removed in `f6e1616`. It is the most detailed wrong document in the project. |
| `docker-compose.rpi5.yml` | Superseded by this repo's `docker-compose.yml`; also pulls the wrong registry name. |
| `docker-compose.rpi5.hailo.yml` | Superseded by `docker-compose.hailo.yml`. Its header already contradicts the README next to it. |
| `.env.example` | Superseded. |
| `nginx.conf` | Now lives here. Keep one copy — this one. |

Leave a one-line `deploy/docker/README.md` pointing at
`github.com/unsilo/photog-docker` and noting that `Dockerfile.web` and
`build-and-push.sh` are the build side.

### 8. Delete `web/Dockerfile`

Redundant and subtly broken: it builds HailoRT it no longer needs, runs as a
bare `USER 1000:1000` with no `/etc/passwd` entry (so `HOME` is unset and
`System.user_home!()` raises), and lacks `uv`, so it cannot compile
`MoondreamInterpreter` as `mix.exs` stands.

### 9. Rotate the SendGrid key

Still open from `claude/docker-web-image.md`. It was inline in `runtime.exs`,
which is copied verbatim into the release, and it is in git history regardless
of what the image contains.

### 10. Tag the source

```bash
cd ~/projects/photog
git tag -a v0.1.0 -m "PhoTog 0.1.0"
git push --tags
```

### 11. Verify `strip_beams`

`mix.exs` does not set it, so it defaults to `true` — which is what you want.
Confirm on the built image rather than assuming:

```bash
docker run --rm --entrypoint sh photog:test -c \
  'ls /app/lib/pho_tog-0.1.0/ebin | head'
```

Then check one module has no `Dbgi` chunk. Per `claude/release-strategy.md` §3
this is obfuscation, not protection — module, function and atom names survive
regardless — but a release with debug info intact is a buildable source tree.

### 12. Scan the image for leaked secrets

```bash
docker history --no-trunc photog:test | grep -iE 'key|secret|password|token'
dive photog:test          # or: docker save photog:test | tar -tv | less
```

Specifically confirm no `.env`, no `deploy/hosts/secrets.env`, no SendGrid key,
and no `.git` in any layer.

---

## Known-untrue claims to fix or accept

| Claim | Where | Status |
|---|---|---|
| Hailo overlay works | `docs/hailo.md`, `docker-compose.hailo.yml` | **Untested.** Marked experimental everywhere it appears. The host-mount approach is sound in principle; the Python-ABI constraint is real and documented. Verify on `photog-10` (Trixie, Python 3.13) — that box should be the one that works. |
| `PhoTog.Release.create_admin/2` recovery | `docs/troubleshooting.md`, `docs/configuration.md` | Function exists at `lib/pho_tog/release.ex:183`. Not run through `bin/pho_tog eval` in a container. |
| The import folder works | `README.md`, `docker-compose.yml` | `PHOTOG_PHOTO_SOURCE=/import` is set and bind-mounted, but the app's default was `/home/photo/sample_photos` — a host path that has never existed in a container. Confirm the import screen actually starts there. |
| `pg_dump`/`pg_restore` recipes | `docs/upgrading.md` | Standard Postgres, not run against this stack. |
| Idle memory is "higher than it should be" | `README.md` | True per `claude/docker-web-image.md`; no number measured. Measure one and put it in the README — "PhoTog idles at N MB" is the question every self-hoster asks first. |

---

## Deliberately out of scope for 0.1.0

- HTTPS. Documented as absent.
- Wheel-baked Hailo image variants (`:0.2.0-hailort4.20`). Named as future in
  `docs/hailo.md`; do not promise a date.
- GHCR mirror. `claude/release-strategy.md` §2 recommends it for users behind
  shared NAT. Docker Hub alone is fine for a first release.
- A `NOTICES` third-party attribution file. Required by the MIT/Apache terms of
  the bundled dependencies and referenced in `release-strategy.md` §5. Generate
  it before anything resembling a wider announcement.
- Signed images / provenance attestation.

---

## A note on the licence

`LICENSE` was drafted from `claude/release-strategy.md` §3, which calls for a
proprietary EULA covering personal use, no redistribution and no reverse
engineering. It is written to be readable and to say what you appear to mean.

**It has not been reviewed by a lawyer, and it was not written by one.** Two
clauses in particular are worth a real opinion before you rely on them: the
"internal business purposes" carve-out in §3, and the split in §8 that puts this
repository's files under MIT while the image stays proprietary. The split is
deliberate — people need to fork a compose file — but the boundary between "the
Configuration Files" and "the Software" is the sort of line that wants precise
drafting.
