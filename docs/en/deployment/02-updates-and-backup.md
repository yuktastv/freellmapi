**English** · [简体中文](../../zh-cn/deployment/02-updates-and-backup.md)

# Updates and backup

Keeping a Docker deployment current, protecting the SQLite data volume, and making installs reproducible with declarative configuration.

- [Upgrading the container](#upgrading-the-container)
- [Switching from the upstream image](#switching-from-the-upstream-image)
- [Dashboard update checker (#635 / #703)](#dashboard-update-checker-635--703)
- [Backing up the SQLite data volume](#backing-up-the-sqlite-data-volume)
- [Declarative config & catalog controls (#f4cd7b4)](#declarative-config--catalog-controls-f4cd7b4)

## Upgrading the container

`docker-compose.yml` runs `ghcr.io/yuktastv/freellmapi:${FREELLMAPI_IMAGE_TAG}`. The tag is required (there is no default) and should be an immutable `sha-<commit>` tag. To upgrade:

1. Back up the data volume (see [Backing up the SQLite data volume](#backing-up-the-sqlite-data-volume)). Migrations only run forward; there is no automatic downgrade, so the backup is your rollback.
2. In `.env`, change `FREELLMAPI_IMAGE_TAG` to the new `sha-<commit>` tag.
3. Re-create the container on the new image:

```bash
docker compose pull && docker compose up -d
```

Three invariants across any upgrade:

1. **Keep the same `.env` `ENCRYPTION_KEY`.** Provider keys are encrypted at rest; a changed key makes every stored key undecryptable. See [02-security-and-keys.md](../env/02-security-and-keys.md).
2. **Keep the same data volume** (`freellmapi-data` at `/app/server/data`) **and the same Compose project name** (the directory name, unless you pass `-p`). The volume is named `<project>_freellmapi-data`, so a different project name starts with an empty database. Migrations run idempotently on boot.
3. **Only move forward.** Never point an install at an image older than the one that last ran against its database (see the next section).

For Docker installs the dashboard's update dialog prints a command that pulls and restarts only once `.env` already names the new tag. It reads `.env` but never edits it, because `.env` holds `ENCRYPTION_KEY`.

## Switching from the upstream image

An install that has been running upstream's image (`ghcr.io/tashfeenahmed/freellmapi`) must not be switched to this fork until you have checked that its database is compatible. The migration runner applies the migrations it knows and **silently ignores any applied migration it does not know**. If upstream's image is newer than this fork, it may already have changed the schema in ways this fork's code does not expect, and nothing will warn you. There is no automatic downgrade.

Do all of this before changing the image:

1. **Find the image and version you run now.**

   ```bash
   CID="$(docker ps -q --filter label=com.docker.compose.service=freellmapi)"
   docker inspect --format '{{.Config.Image}} version={{ index .Config.Labels "org.opencontainers.image.version" }} revision={{ index .Config.Labels "org.opencontainers.image.revision" }}' "$CID"
   ```

   Settings in the dashboard also shows the running release. This fork's release is the `version` in [`desktop/package.json`](../../../desktop/package.json). If the image you run is a newer release than that, stop: do not switch.

2. **Confirm database compatibility.** List the migrations your database has applied, and compare them with the migrations this fork ships (run from your checkout of this fork):

   ```bash
   docker exec "$CID" node -e "const D=require('better-sqlite3');const d=new D(process.env.FREEAPI_DB_PATH||'/app/server/data/freeapi.db',{readonly:true});for(const r of d.prepare('SELECT filename FROM migrations ORDER BY filename').all())console.log(r.filename)" > applied-migrations.txt
   ls server/src/db/migrations | grep '\.ts$' | sort > fork-migrations.txt
   comm -23 applied-migrations.txt fork-migrations.txt
   ```

   The database is opened read-only. **No output means compatible.** Any line printed is a migration your database already has that this fork does not know: do not switch.

3. **Back up the persistent volume and `.env`.** Stop the container so SQLite is consistent, archive the volume, and keep a copy of `.env` (it holds `ENCRYPTION_KEY`; without it the backup's provider keys cannot be decrypted). Store both somewhere private.

   ```bash
   VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/server/data"}}{{.Name}}{{end}}{{end}}' "$CID")"
   docker stop "$CID"
   docker run --rm -v "$VOLUME":/data:ro -v "$PWD":/backup alpine tar czf /backup/freellmapi-data-backup.tgz -C /data .
   cp -p .env .env.backup && chmod 600 .env.backup
   ```

4. **Switch.** Use this fork's `docker-compose.yml` from the same directory, so the project name and volume stay the same. Keep your `ENCRYPTION_KEY`, set `FREELLMAPI_IMAGE_TAG` to this fork's `sha-<commit>` tag, then `docker compose pull && docker compose up -d`. Confirm with `docker compose images freellmapi` that it now runs `ghcr.io/yuktastv/freellmapi`.

To roll back, stop the container, restore the archive into the volume, and start the image you were running before. Never run an older image against a database a newer one has migrated.

## Dashboard update checker (#635 / #703)

Settings carries a single update surface: it reports the running release, lists recent commits, and — when the installation is Docker — prints an upgrade command that runs `docker compose pull && docker compose up -d` once `FREELLMAPI_IMAGE_TAG` in `.env` names the new `sha-<commit>` tag. Relevant controls:

| Variable | Default | Purpose |
| --- | --- | --- |
| `FREELLMAPI_UPDATE_CHECK` | Enabled | Set to `off` to hide the checker from Settings and prevent Git discovery or outbound update-check requests. This also switches off the automatic release reminder, a separate dashboard setting (Settings > General) that is off until turned on there. |
| `FREELLMAPI_UPDATE_GITHUB_TOKEN` | Empty (anonymous checks) | Optional token used only for update checks against GitHub. Use a narrowly scoped token only if higher rate limits are needed; generic `GITHUB_TOKEN` values are intentionally ignored. |

Two build-level facts back the version display: `FREELLMAPI_INSTALL_METHOD=docker` tells the server which upgrade path to suggest, and the runtime image copies `desktop/package.json` — where the release version lives, since `server/package.json` tracks the workspace — as a ~400-byte manifest so a container install can name its own version (#703).

## Backing up the SQLite data volume

Everything that matters lives in one place: the named volume `freellmapi-data` mounted at `/app/server/data`, containing the SQLite database (`freeapi.db`, or wherever `FREEAPI_DB_PATH` points), its `-wal`/`-shm` sidecars, and the `.encryption-key` file for dev-style installs. Back up all of it together, and keep the matching `ENCRYPTION_KEY` safe — without it, backed-up provider keys are undecryptable ciphertext.

Built-in encrypted backups (recommended, zero downtime). FreeLLMAPI can push an encrypted backup of the live database on a schedule:

```env
FREEAPI_DB_BACKUP_PATH=/app/server/data/freellmapi.db.backup
# or:
FREEAPI_DB_BACKUP_URL=https://example.com/freellmapi.db.backup
FREEAPI_DB_BACKUP_TOKEN=optional-bearer-token
FREEAPI_DB_BACKUP_KEY=64-char-hex-backup-key        # defaults to ENCRYPTION_KEY
FREEAPI_DB_BACKUP_INTERVAL_MS=300000
```

Restore semantics: when the configured database file is missing at startup, FreeLLMAPI restores the backup before migrations run; while the server is running it uploads a fresh encrypted backup periodically. On hosts with ephemeral disks this is the primary protection.

Volume snapshot (plain Docker approach). The standard pattern works unchanged:

```bash
docker run --rm -v freellmapi-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/freellmapi-data.tar.gz -C /data .
```

Because the server keeps the database open (WAL mode), prefer doing this while the container is stopped (`docker compose stop`) so you capture a quiescent copy, then `docker compose start`.

## Declarative config & catalog controls (#f4cd7b4)

For repeatable Docker/server installs, FreeLLMAPI can apply a JSON config on every boot. Set `FREEAPI_CONFIG_PATH=/path/to/freellmapi.config.json`, or put the same JSON inline in `FREEAPI_CONFIG_JSON`. The application is idempotent: existing keys, custom providers, model edits, fallback rows, and routing settings are updated instead of duplicated, after migrations, on every boot.

```json
{
  "keys": [
    { "platform": "groq", "key": "gsk_...", "label": "main" },
    { "platform": "google", "key": "AIza...", "enabled": true }
  ],
  "customProviders": [
    {
      "baseUrl": "http://host.docker.internal:11434/v1",
      "label": "Ollama",
      "models": [
        { "model": "llama3.1:8b", "displayName": "Local Llama", "supportsTools": true }
      ]
    }
  ],
  "models": [
    {
      "platform": "groq",
      "modelId": "llama-3.3-70b-versatile",
      "displayName": "Llama 3.3 70B",
      "supportsTools": true,
      "fallbackEnabled": true
    }
  ],
  "routing": { "strategy": "balanced" }
}
```

If two custom endpoints serve the same model id, add `"endpoint"` to a `models` or `fallback` entry to say which one you mean — the endpoint's URL, or the short handle the dashboard shows next to it. Without it, an entry that matches more than one endpoint is rejected rather than applied to an arbitrary one:

```json
{
  "models": [
    { "platform": "custom", "modelId": "deepseek-v3.1", "endpoint": "https://relay-b.example.com/v1", "enabled": false }
  ]
}
```

Catalog side: an install keeps its model roster current from the signed catalog feed (the full catalog is listed at freellmapi.co/models), so no manual roster maintenance is required alongside upgrades.
