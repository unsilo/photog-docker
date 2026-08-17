# Reverse geocoding — place tags from GPS coordinates

Photos carry GPS coordinates in their EXIF. Turning those into country, state
and place tags needs a gazetteer — a list of places with coordinates — and
Photog can get one two ways.

**Both are optional, neither implies the other, and having neither is a
supported configuration.** With no source at all, photos import normally, keep
their GPS EXIF, and sit in the Unlocated smart album where you can place them by
hand. Nothing is broken and nothing nags you.

| | account | data leaves the machine | speed | disk |
|---|---|---|---|---|
| **Local gazetteer** | none | no | full import speed | ~15 MB download, ~185k rows |
| **geonames.org web service** | free, yours | yes — every photo's coordinates | ~900 photos/hour | none |
| **Both** | free, yours | only on a local miss | full speed | as above |
| **Neither** | — | — | — | — |

Set both and the local data answers first, with the web service as a genuine
fallback for coordinates no town is near.

---

## Which am I on right now?

Ask, rather than reading the config and guessing:

```bash
cd ~/photog
docker compose exec photog /app/bin/pho_tog eval 'PhoTog.Geo.Diagnostics.print()'
```

That prints the active mode, the gazetteer row count, the account if there is
one, and — the useful part — how many of your photos have coordinates, how many
are placed, and how many are waiting. It ends with a verdict naming the one
thing standing between you and place tags.

Read the verdict before changing anything. The most common cause of "no place
tags" is not the geocoder at all: it is photos with no GPS EXIF, which no
geocoder can place and which land in **UnPlaced** rather than **Unlocated**.
Those two piles are different and the diagnostic distinguishes them.

---

## Option 1: the local gazetteer

GeoNames publishes the same data it serves, under CC BY 4.0. Loading it locally
means no account, no quota, no rate limit, and no coordinates sent anywhere.

### On a new install

In `.env`:

```
PHOTOG_LOAD_GAZETTEER=true
```

```bash
docker compose up -d
```

The next boot downloads ~15 MB from `download.geonames.org` and loads ~185,000
towns. That boot takes several minutes and the container reports itself
unhealthy while it works — the healthcheck allows a 300-second start period for
exactly this. Watch it:

```bash
docker compose logs -f photog
```

Leave the variable set. `ensure_loaded/1` checks the table before downloading
anything, so every boot after the first is a single query.

### On an install that is already running

You do not have to restart. This does the same work immediately:

```bash
docker compose exec photog /app/bin/pho_tog eval 'PhoTog.Release.load_gazetteer()'
```

It runs in the foreground and prints progress. Set `PHOTOG_LOAD_GAZETTEER=true`
in `.env` afterwards anyway, so a future `docker compose down -v` does not
quietly leave you without it.

### Then push the backlog

**Loading the gazetteer does not place photos you have already imported.**
Geocoding runs on import, so a library that predates the gazetteer sits in
Unlocated indefinitely and looks exactly like a broken geocoder.

Open the **Repairs** panel and click reload on the **Unlocated** entry. Watch
the log while it runs — every photo comes out as one of placed / skipped /
failed in the batch summary, with a reason attached to each failure.

### Rebuilding or changing the dataset

```bash
# rebuild against a fresh dump
docker compose exec photog /app/bin/pho_tog eval 'PhoTog.Release.load_gazetteer(force: true)'

# load a different dataset
docker compose exec photog /app/bin/pho_tog eval 'PhoTog.Release.load_gazetteer(dataset: "cities1000")'
```

| dataset | places | |
|---|---|---|
| `cities15000` | ~25,000 | towns over 15,000, plus capitals |
| `cities5000` | ~50,000 | |
| `cities1000` | ~130,000 | |
| `cities500` | ~185,000 | **the default** — towns over 500 |

Bigger is more precise in empty country and no more precise in a city. The
import truncates and reloads inside one transaction, so a failure halfway
through leaves the old data in place rather than an empty table.

---

## Option 2: the geonames.org web service

Needs a free account, and the account has to be **yours** — the quota is per
username, and every photo's coordinates go to a third party.

1. Register at <https://www.geonames.org/login>
2. On your account page, **enable the username for the free web services**

Step 2 is the one everyone misses. A new account can log in and still have every
API call rejected until that box is ticked.

In `.env`:

```
PHOTOG_GEONAMES_USERNAME=your-account
#PHOTOG_GEONAMES_LANGUAGE=en
```

```bash
docker compose up -d
```

`PHOTOG_GEONAMES_BASE_URL` is only for the paid endpoint
(`https://secure.geonames.net`). Leave it unset for the free service.

The free tier is 1000 credits/hour, so requests are throttled to roughly 900 per
hour — about four seconds per photo. A large first import will take a while.
That throttle is paid only by the online path; a gazetteer install imports at
full speed.

---

## Upgrading

The gazetteer survives upgrades and needs nothing done to it. The rows are in
Postgres and the downloaded dumps are in `/app_cache/geonames`, which is the
`photog-cache` volume — `docker compose pull && up -d` touches neither.

Two things to check on an install that predates the gazetteer:

- **Run the diagnostic.** Early versions shipped a shared geonames.org account
  compiled into the image. That is gone, so an install that used to get place
  tags without any configuration now gets none, silently. If
  `Diagnostics.print()` reports `mode NONE`, that is what happened — pick a
  source above.
- **Refresh your compose files.** `PHOTOG_LOAD_GAZETTEER` has to be present in
  the `photog` service's `environment:` block to reach the container at all.
  Compose does not pass through variables it has not been told about, so an
  older `docker-compose.yml` will ignore the setting no matter what `.env` says.
  See [upgrading.md](upgrading.md) for how to refresh them.

---

## Troubleshooting

**No place tags, and the diagnostic says a source is configured.** Nothing has
pushed the photos at the pipeline. Geocoding runs on import; use Repairs →
Unlocated.

**No place tags, and `with coordinates` is 0.** Your photos have no usable GPS
EXIF. Check one original with `exiftool -gps:all`. Nothing in this document will
help — these are UnPlaced, not Unlocated.

**Places resolve to the wrong town.** The local query widens its search in rings
up to 20 degrees, so a coordinate in open country or at sea will resolve to
something distant rather than to nothing. That is deliberate.

**`service "web" is not running`.** The service is named `photog`. Older
documentation says `web`; it is wrong.
