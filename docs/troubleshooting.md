# Troubleshooting

Organised by what you see. Run everything from your PhoTog directory
(`~/photog` by default).

First two commands, always:

```bash
docker compose ps
docker compose logs --tail=100 photog
```

Hailo problems have [their own page](hailo.md).

---

## Nothing is listening / the browser cannot connect

**Check what is actually running.**

```bash
docker compose ps
```

You should see `db`, `photog` and `proxy`. If `proxy` is missing or restarting:

```bash
docker compose logs proxy
```

### `host not found in upstream` or the proxy exits immediately

Usually `nginx.conf` is not a file. Docker creates a **directory** at a
bind-mount source that does not exist, and nginx fails on a config path that is
not a file.

```bash
ls -l nginx.conf
```

If that shows a directory, remove it and fetch the real file:

```bash
rmdir nginx.conf
curl -fsSLO https://raw.githubusercontent.com/unsilo/photog-docker/main/nginx.conf
docker compose up -d
```

### `bind: address already in use`

Something else owns port 80.

```bash
sudo ss -ltnp | grep ':80 '
```

Stop it, or move PhoTog:

```
PHOTOG_HTTP_PORT=8080
PHOTOG_IMAGE_URL_BASE=http://photog.local:8080
```

Both lines. Setting only the first gives you a working site where no image
loads.

### `photog.local` does not resolve

mDNS is not universal. From another machine:

```bash
ping photog.local
```

If that fails, use the IP address instead — and then set:

```
PHX_HOST=192.168.1.50
```

or, to keep the name working where it does resolve, leave `PHX_HOST` alone and
add the IP to the origin list:

```
PHOTOG_CHECK_ORIGIN=http://photog.local,http://192.168.1.50
PHOTOG_IMAGE_URL_BASE=http://192.168.1.50
```

Windows clients need Bonjour for `.local` names; many networks do not pass mDNS
across subnets or VLANs.

---

## `no matching manifest for linux/amd64`

The 0.1.0 image is published for **`linux/arm64` only** and this is an x86-64
machine. Nothing is broken and nothing in `.env` will fix it.

See "arm64 only, for now" in the README. Either run PhoTog on an arm64 machine —
a Raspberry Pi, an Apple Silicon Mac, an arm64 VM — or wait for the amd64 image.

Under emulation, if you want to try it anyway:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

then add to `.env`:

```
DOCKER_DEFAULT_PLATFORM=linux/arm64
```

It will work and it will be slow. The numerical runtime the app loads at boot is
close to the worst case for QEMU.

---

## `exec format error` in the logs

Same cause as above, one step later: the image was pulled for the wrong
architecture and the binaries inside it will not run.

```bash
docker image inspect tehsnappysoftware/photog:0.1.0 --format '{{.Architecture}}'
uname -m
```

---

## The app container restarts in a loop

```bash
docker compose logs --tail=100 photog
```

### `SECRET_KEY_BASE` or `PHX_HOST` missing

The app refuses to boot without them. Check `.env` has real values — not blank,
not still `=`.

### Database connection refused

The app waits on Postgres's healthcheck, so this usually means Postgres itself
is unhealthy:

```bash
docker compose logs db
```

### `Ecto.InvalidURLError`, or authentication failures against the database

`POSTGRES_PASSWORD` contains a character that changes how a URL parses. Use hex:

```bash
openssl rand -hex 24
```

If the database already exists, changing `POSTGRES_PASSWORD` in `.env` does
**not** change it in the database — the role was created on the first run. Either
put the original back, or change it in Postgres:

```bash
docker compose exec db psql -U photog -d pho_tog_prod \
  -c "ALTER ROLE photog WITH PASSWORD 'new-hex-password';"
```

then update `.env` and `docker compose up -d`.

### A migration fails

Get in without running them:

```
PHOTOG_SKIP_MIGRATIONS=true
```

```bash
docker compose up -d
docker compose exec photog /app/bin/pho_tog remote
```

Then open an issue with the migration error. Remove the variable afterwards.

---

## I cannot log in

There is no password reset — the mailer is not configured in this image.

The admin account is created on first boot **and only while the users table is
empty**. If the stack booted once with a blank `PHOTOG_ADMIN_PASSWORD`, or the
password was under 12 characters, no account was created and setting the
variable now does nothing.

Create one directly:

```bash
docker compose exec photog \
  /app/bin/pho_tog eval 'PhoTog.Release.create_admin("you@example.com", "a-long-password")'
```

At least 12 characters, at most 72 bytes — bcrypt truncates past that, so a very
long passphrase is rejected rather than silently shortened.

---

## The page loads but nothing is interactive

Buttons do nothing, the gallery does not update, and the browser console shows a
transport error or a rejected websocket.

The origin you reached the server on is not in the allowed list. This is almost
always because you used an address that is not `PHX_HOST` — an IP instead of a
name, or a port.

```
PHOTOG_CHECK_ORIGIN=http://photog.local,http://192.168.1.50,http://photog.local:8080
```

```bash
docker compose up -d
```

Behind a TLS terminator, list the public `https://` origin, and make sure the
terminator forwards `Upgrade` and `Connection` headers.

---

## Pages load but every thumbnail is broken

Image URLs are **absolute**, built from `PHOTOG_IMAGE_URL_BASE`. If it does not
match the origin you are browsing from, every `<img>` points at an address the
browser cannot reach — and the URLs look perfectly correct in devtools, which is
what makes this take an hour.

Open devtools, look at a broken image's URL, and compare it with what is in your
address bar. Then set `PHOTOG_IMAGE_URL_BASE` to the address bar's origin,
including the port if there is one.

If the URL is right and the response is a 404 from PhoTog itself, the warehouse
is the problem — see below.

---

## Imports appear to work but no thumbnails ever appear

Almost always a permissions problem on the warehouse directory. The container
runs as **uid 1000** and cannot write a root-owned directory.

```bash
ls -ld /mnt/photos          # or whatever PHOTOG_WAREHOUSE_PATH points at
sudo chown -R 1000:1000 /mnt/photos
docker compose restart photog
```

If you are using the default named volume, this cannot be it — check the logs
for the actual write error:

```bash
docker compose logs photog | grep -iE 'eacces|permission|enoent'
```

---

## The import screen shows an empty folder

The `import` directory did not exist when the stack first came up, so Docker
created it as root.

```bash
ls -ld import
sudo chown 1000:1000 import
```

Then put photos in `~/photog/import` and refresh. Or point
`PHOTOG_IMPORT_PATH` at somewhere else entirely.

## The import page crashes when I start an import

If the source directory typed into the import form does not exist, the page
crashes rather than telling you so — and it creates the import record first, so
you get a stray empty import in the list.

Check the path exists **inside the container**, which is not the same as on the
host:

```bash
docker compose exec photog ls -la /import
```

A path that is right on the host and wrong in the container is the usual cause:
only `/import` and the warehouse are mounted. Anything else you type into that
form has to be reachable from inside the container.

---

## It is very slow

**First boot is slow on purpose** — migrations, seeding, and asset warm-up. Give
it a few minutes on a Pi.

**Imports are I/O bound.** On an SD card they will be slow no matter what else
you do. Move the warehouse to an SSD (`PHOTOG_WAREHOUSE_PATH`) before importing
a real library.

**Check you are not swapping:**

```bash
free -h
docker stats --no-stream
```

Idle memory use is higher than it should be in 0.1.0 — the numerical runtime
loads at boot whether or not any classifier is enabled.

**Postgres is competing for the same cores.** On a Pi, `POOL_SIZE=6` is about
right; raising it does not help.

---

## Uploads from the iOS or macOS client fail

The proxy accepts bodies up to 1 GB and holds the connection for 10 minutes on
the upload path, which covers anything reasonable. If uploads fail anyway:

```bash
docker compose logs proxy | tail -50
```

A `413` means something in front of PhoTog has a smaller limit than nginx does —
check your TLS terminator or router.

---

## Disk is filling up

```bash
docker system df
du -sh /mnt/photos          # or your warehouse path
```

Container logs are capped at 30 MB per service. The warehouse and the database
are not capped by anything.

Old images add up after a few upgrades:

```bash
docker image prune -a
```

That only removes images no container is using. It is safe; it does not touch
volumes.

---

## Starting over

Keep the photos, reset everything else:

```bash
docker compose down
docker volume rm photog_photog-db
docker compose up -d
```

Delete **everything**, photos included, with no confirmation prompt:

```bash
docker compose down -v
```

---

## Getting help

Open an issue at
[github.com/unsilo/photog-docker/issues](https://github.com/unsilo/photog-docker/issues)
with:

```bash
docker compose ps
docker compose logs --tail=200 photog
docker compose logs --tail=50 proxy
uname -m && docker --version && docker compose version
```

and your `.env` **with the secrets removed**:

```bash
sed -E 's/^(SECRET_KEY_BASE|POSTGRES_PASSWORD|PHOTOG_ADMIN_PASSWORD)=.*/\1=REDACTED/' .env
```
