# Docker Guide

Docker Compose is the recommended way to run FreeLLMAPI for personal use. The container serves the Express API and the built React dashboard from one process on port 3001, with SQLite persisted in a named volume.

## Prerequisites

- Docker
- Docker Compose
- OpenSSL for generating `ENCRYPTION_KEY`

## Quick Start

Create a `.env` file with a 32-byte encryption key and the image tag to run. `FREELLMAPI_IMAGE_TAG` is required (Compose refuses to start without it); pin the immutable `sha-<commit>` tag of the commit you checked out:

```bash
ENCRYPTION_KEY="$(openssl rand -hex 32)"
IMAGE_TAG="sha-$(git rev-parse --short=7 HEAD)"
printf "ENCRYPTION_KEY=%s\nPORT=3001\nFREELLMAPI_IMAGE_TAG=%s\n" "$ENCRYPTION_KEY" "$IMAGE_TAG" > .env
```

Already running the upstream image? Check database compatibility and back up the data volume before switching: see [Switching from the upstream image](../docs/en/deployment/02-updates-and-backup.md#switching-from-the-upstream-image).

Start the app:

```bash
docker compose up -d
```

Open http://localhost:3001, add provider keys on the **Keys** page, then use the generated `freellmapi-...` key with any OpenAI-compatible client.

## Example API Call

```bash
curl http://localhost:3001/v1/chat/completions \
  -H "Authorization: Bearer freellmapi-your-unified-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Say hello from FreeLLMAPI."}]
  }'
```

## Operations

Check status:

```bash
docker compose ps
```

Tail logs:

```bash
docker compose logs -f freellmapi
```

Stop the app:

```bash
docker compose down
```

Update: back up the data volume, set `FREELLMAPI_IMAGE_TAG` in `.env` to the new `sha-<commit>` tag, then:

```bash
docker compose pull
docker compose up -d
```

Rebuild locally from source:

```bash
docker compose up -d --build
```

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `ENCRYPTION_KEY` | Yes | None | 64-character hex key used to encrypt provider API keys at rest. Generate it once and keep it stable. |
| `FREELLMAPI_IMAGE_TAG` | Yes | None | Tag of `ghcr.io/yuktastv/freellmapi` to run. Use an immutable `sha-<commit>` tag; `main` moves with every merge. |
| `PORT` | No | `3001` | Host port exposed by Docker Compose. The container listens on port 3001. |
| `FREEAPI_DB_PATH` | No | `/app/server/data/freellmapi.db` | SQLite file path. Set this when your host only persists one mounted directory. |
| `FREEAPI_DB_BACKUP_PATH` | No | None | Local encrypted backup file. Restored on startup if the DB file is missing, then refreshed while the app runs. |
| `FREEAPI_DB_BACKUP_URL` | No | None | HTTP(S) encrypted backup target. Startup uses `GET`; periodic backups use `PUT`. |
| `FREEAPI_DB_BACKUP_TOKEN` | No | None | Optional bearer token for `FREEAPI_DB_BACKUP_URL`. |
| `FREEAPI_DB_BACKUP_KEY` | No | `ENCRYPTION_KEY` | 64-character hex key for backup encryption. Use a separate stable key if possible. |
| `FREEAPI_CONFIG_PATH` | No | None | JSON config file applied idempotently after migrations on every boot. |
| `FREEAPI_CONFIG_JSON` | No | None | Inline JSON config. Takes precedence over `FREEAPI_CONFIG_PATH`. |

The `freellmapi-data` volume stores SQLite data at `/app/server/data`. Keep the same volume and `ENCRYPTION_KEY` when upgrading, otherwise existing encrypted provider keys cannot be decrypted.

Example `freellmapi.config.json`:

```json
{
  "admin": { "email": "ops@example.com", "password": "change-me-min-8-chars" },
  "license": "premium license key from freellmapi.co",
  "keys": [
    { "platform": "groq", "key": "gsk_...", "label": "main" }
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
  "routing": { "strategy": "balanced" }
}
```

The optional `admin` entry creates the first dashboard account while no account
exists (ignored with a warning afterwards — a claimed install can't be taken
over by config), and `license` activates a Premium key against the license
service in the background. Both fields are optional; the file carries plaintext
secrets, so protect it like `ENCRYPTION_KEY`.

## Published Image

Images are published to GitHub Container Registry:

```bash
docker pull ghcr.io/yuktastv/freellmapi:sha-<commit>
```

Tags: `sha-<commit>` for every `main` commit (immutable; recommended for production), `main` (moves with every merge), and `v*.*.*` plus `latest` once a release tag is pushed (none yet).

The Docker workflow builds pull requests without pushing. After this repository receives the workflow on `main`, pushes to `main` and version tags publish images to GHCR automatically.
