// The command a source install runs to update. The server reports the
// owner/name it compared against (FREELLMAPI_UPDATE_REPOSITORY, default this
// fork), so a fork's checkout is never told to merge upstream's main.
export const DEFAULT_UPDATE_REPOSITORY = 'yuktastv/freellmapi'

const REPOSITORY_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_.-]{1,100}$/

const SHORT_SHA = /^[0-9a-f]{7}$/

// docker-compose.yml requires FREELLMAPI_IMAGE_TAG and an install should pin an
// immutable sha-<commit> tag, so updating means changing that tag in .env.
// This command never edits .env (it holds ENCRYPTION_KEY); it only READS it:
// it pulls and recreates the container once the tag already names the new
// image, and otherwise says which tag to set and changes nothing.
export function dockerUpdateCommand(remoteSha?: string): string {
  if (!remoteSha || !SHORT_SHA.test(remoteSha)) {
    return '# Set FREELLMAPI_IMAGE_TAG=sha-<commit> in .env, then: docker compose pull && docker compose up -d'
  }
  const line = `FREELLMAPI_IMAGE_TAG=sha-${remoteSha}`
  return `if grep -qx '${line}' .env; then docker compose pull && docker compose up -d; else echo 'Set ${line} in .env, then run this again'; fi`
}

export function sourceUpdateCommand(repository?: string): string {
  // The value lands in a shell command the user copies, so anything that is
  // not a plain owner/name falls back rather than being interpolated.
  const repo = repository && REPOSITORY_PATTERN.test(repository) ? repository : DEFAULT_UPDATE_REPOSITORY
  return `git fetch https://github.com/${repo}.git main && git merge --ff-only FETCH_HEAD && npm ci && npm run build`
}
