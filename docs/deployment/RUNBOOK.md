# FreeLLMAPI release dc35b37: staging and production runbook

Release commit: `dc35b37eb9b1ec407d96530fd6d3dd56d2e3327d` (PRs #2, #3, #4 merged; CI green on Node 20/22/24)

Verified image (tag and digest):

```
ghcr.io/yuktastv/freellmapi:sha-dc35b37@sha256:d5ff1a87e9e39d7449e313d108e535d48d13c006966e39e86ee243de18ab35ed
```

- `linux/amd64` `sha256:090e4751e8ef560922f4039713a9785c49fab88b16f6a3814ac9dcadd56e9c49`
- `linux/arm64` `sha256:3ce0c5167a9708cfb1bb8cc505d6e3e2c3e1001cc24873a24b2e5de805732a52`
- Both platforms carry `org.opencontainers.image.revision` = the full SHA and `org.opencontainers.image.source` = `https://github.com/yuktastv/freellmapi`.

Copy this directory to each host. Every script prints `OK`/`FAIL` lines and stops at the first unsafe condition. None prints `ENCRYPTION_KEY`, passwords or API keys.

```bash
export RELEASE_SHA=dc35b37eb9b1ec407d96530fd6d3dd56d2e3327d
export RELEASE_IMAGE='ghcr.io/yuktastv/freellmapi:sha-dc35b37@sha256:d5ff1a87e9e39d7449e313d108e535d48d13c006966e39e86ee243de18ab35ed'
```

Prerequisites on each host: Docker with Compose v2.24 or later, git, curl, python3, openssl, sha256sum, and nginx with a valid TLS certificate. Use the server block in `docs/en/proxy/02-nginx.md`, `proxy_pass http://127.0.0.1:3001`, and make it the `default_server`.

## Staging

1. **Re-verify the image** (any machine): `./verify-image.sh "$RELEASE_SHA"`. It must print the same `IMAGE=` line as above.
2. **Check out the release** (staging host): `git clone https://github.com/yuktastv/freellmapi.git freellmapi-staging && cd freellmapi-staging && git checkout "$RELEASE_SHA"`
3. **Deploy** (staging host): `./staging-deploy.sh ~/freellmapi-staging`
   - Uses Compose project `freellmapi-staging`, which has its own volume.
   - A fresh install gets a NEW encryption key. An existing staging install keeps its key and is migration-checked and backed up first.
4. **Outside-in checks** (another machine, BEFORE creating the account): `BASE_URL=https://<staging> STAGING_IP=<public ip> ./staging-external-checks.sh`
   - Covers tests 4 (spoofed local trust → 403), 5 (port 3001 not public) and 9 (TLS and forwarding headers).
5. **Create the first account** with the setup code: `docker logs <container> 2>&1 | grep 'First-run setup code'`. Read it privately.
6. **Host-side tests** (staging host): `BASE_URL=https://<staging> ADMIN_EMAIL=... ADMIN_PASSWORD=... ./staging-host-tests.sh ~/freellmapi-staging`
   - Covers tests 1, 2, 3, 6, 7, 8 and 10, and leaves Ollama emulation OFF.

## Production (only after staging passes, and with separate approval)

1. On the production host, switch the EXISTING install directory to the fork at the release commit. Keep the directory, so the Compose project name and volume stay the same. `.env` is untracked and is not touched.

   ```bash
   cd <install dir> && git remote set-url origin https://github.com/yuktastv/freellmapi.git && git fetch origin && git checkout "$RELEASE_SHA"
   ```

2. **Dry run** (read-only):
   - It identifies the running image, digest and revision, and the volume.
   - It runs the migration compatibility check and refuses a downgrade.
   - It checks the configuration.

   ```bash
   DRY_RUN=1 PROD_PROJECT=<existing project> BASE_URL=https://<prod> ./prod-deploy.sh <install dir>
   ```

3. **Deploy:** run the same command without `DRY_RUN`, adding `ADMIN_EMAIL`/`ADMIN_PASSWORD` for the login smoke tests.
   - It stops the container, backs up the volume and `.env` separately, writes checksums, verifies them and the archive, and writes `rollback.env`.
   - It switches to the pinned digest, verifies the running digest and OCI revision, checks that `ENCRYPTION_KEY` is unchanged, that no Watchtower is running, and the logs.
   - It then smoke-tests the API, dashboard, auth and persistence.
4. **Rollback** (image AND matching database together): `CONFIRM=yes ./rollback.sh <backup dir printed by prod-deploy.sh> <install dir>`

## Config the scripts enforce

| Setting | Staging | Production |
|---|---|---|
| Image | release digest (host-local `docker-compose.release.yml`) | same digest |
| `TRUST_PROXY` | `1` (overlay) | `1` |
| `DISABLE_LOCAL_TRUST` | `true` (overlay) | `true` |
| `FREELLMAPI_UPDATE_CHECK` | `off` (overlay) | `off` |
| Self-update / Watchtower | URL/token empty, label opt-out | refused if configured; never `--profile autoupdate` |
| Port | `127.0.0.1:3001` only | `127.0.0.1:3001` only |
