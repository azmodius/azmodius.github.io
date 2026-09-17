# azmodius.moe

Personal site. Jekyll 4, no gem theme — layouts, includes and styles are all local.
Built and deployed by GitHub Actions
([`.github/workflows/pages.yml`](.github/workflows/pages.yml)) on every push to `master`.

## Local preview

The Docker daemon lives in a Colima VM, so it has to be running first.

```sh
colima start
docker compose up
```

Then open <http://localhost:4000>. Edits to `.md`, `_data/`, `_sass/` and `_layouts/`
rebuild automatically and the browser reloads itself.

`^C` to stop; `colima stop` to shut the VM down.

**From VS Code:** Run and Debug → **Site: serve (localhost:4000)** does the same and opens
the browser once Jekyll is actually serving. **Site: stop** runs `docker compose down`.
Colima still has to be running first.

**`_config.yml` is the exception to live reload** — Jekyll reads it once at boot. After
editing it, `docker compose restart`, or the change silently won't appear.

### One-time setup

```sh
brew install colima docker docker-compose
mkdir -p ~/.docker/cli-plugins
ln -sfn /opt/homebrew/lib/docker/cli-plugins/docker-compose \
        ~/.docker/cli-plugins/docker-compose   # makes `docker compose` resolve
```

Nothing else is needed on the host — Ruby 3.3, Bundler and every gem live in the
`ruby:3.3` container. Gems persist in a named volume, so only the first `up` is slow.

### Adding game cover art

Covers are matched by filename, so there is nothing to configure either way.

**`--entrypoint` is required on every `docker compose run` below.** `entrypoint.sh`
ignores its arguments and always starts the server, so
`docker compose run --rm jekyll <anything>` boots Jekyll instead of running `<anything>`.
Or use the **Covers:** configs in `.vscode/launch.json`.

**By hand, no API key.** List every game, its year, its cover, and for a missing cover
the filename to save it as plus search links:

```sh
docker compose run --rm --no-deps --entrypoint bundle jekyll \
  exec ruby script/fetch-covers.rb --list
```

**Automatically, with credentials.** Keys go in `.env` (gitignored):
`IGDB_CLIENT_ID` + `IGDB_CLIENT_SECRET` from https://dev.twitch.tv/console/apps, and
optionally `STEAMGRIDDB_API_KEY`.

```sh
docker compose run --rm --no-deps --env-from-file .env --entrypoint bundle jekyll \
  exec ruby script/fetch-covers.rb --dry-run
```

A run caches name, slug, release year and platforms for every entry with an `igdb_id`
into `_data/igdb.yml`, which the build reads, so **commit that file** (CI has no keys).
It then downloads covers that are missing. It never edits `_data/games.yml`.

Title search never picks a match on its own, because it guesses wrong: "Riftbound"
comes back as "Demonlore" and "Destiny 2" as a GBA game. For entries with no `igdb_id`
it prints candidates for you to pin. `--source igdb|sgdb` forces one source; `--force`
re-downloads existing covers.

Steam's CDN was ruled out even though it needs no key. It only knows Steam titles, and
against this log it matched 0 of 3, attaching art from the wrong games.

### Other commands

```sh
docker compose run --rm --no-deps --entrypoint bundle jekyll update            # rewrites Gemfile.lock
docker compose run --rm --no-deps --entrypoint bundle jekyll exec jekyll build
docker compose down -v                                   # also drops the cached gem volume
```

## Notes

- **`Gemfile.lock` is committed on purpose.** CI installs from it, so local and production
  resolve to identical gem versions. Don't add it back to `.gitignore`.
- **`CNAME` must survive any build.** It's what points `azmodius.moe` here; the workflow
  fails the build if it goes missing from `_site`.
- **Jekyll runs with `--force_polling`.** Colima mounts the project over virtiofs with
  `mountInotify=false`, so file-change events never reach the container and plain
  `--watch` would sit there doing nothing.
- **Sass:** Jekyll 4 uses Dart Sass. Everything is `@use`d from
  `assets/css/style.scss`; don't reintroduce `@import`. A clean build emits **no**
  deprecation warnings — if you see one, it came from something we added.
- **`_sass/pf/_tokens.scss` is the whole skin.** Every color, font and size lives there.
  `_base.scss` and `_components.scss` contain no literals, only `var(--pf-*)`.
- **`_sass/pf/_breakpoints.scss` must never emit CSS.** Media queries need Sass variables
  rather than custom properties; keeping them in a silent file is what stops the palette
  being compiled more than once.
- **Pages need front matter.** A `.md` file without a `---` block is copied verbatim
  instead of rendered, and silently 404s at its pretty URL.
- **Never name an asset with a leading underscore.** Jekyll treats `_`-prefixed files
  and folders as private and omits them from `_site`. The page still references the
  file, so it 404s with nothing in the build log to explain it.
- **Game covers** are matched by filename, not by config. A file at
  `assets/img/games/<jekyll-slug-of-the-title>.<jpg|jpeg|png|webp>` is picked up
  automatically, so adding art needs no edit to `_data/games.yml`. An explicit
  `cover:` key still wins if you want a specific file, and an entry with neither
  gets a typographic card.
