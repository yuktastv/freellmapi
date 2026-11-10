// The command a source install runs to update. The server reports the
// owner/name it compared against (FREELLMAPI_UPDATE_REPOSITORY, default this
// fork), so a fork's checkout is never told to merge upstream's main.
export const DEFAULT_UPDATE_REPOSITORY = 'yuktastv/freellmapi'

const REPOSITORY_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_.-]{1,100}$/

export function sourceUpdateCommand(repository?: string): string {
  // The value lands in a shell command the user copies, so anything that is
  // not a plain owner/name falls back rather than being interpolated.
  const repo = repository && REPOSITORY_PATTERN.test(repository) ? repository : DEFAULT_UPDATE_REPOSITORY
  return `git fetch https://github.com/${repo}.git main && git merge --ff-only FETCH_HEAD && npm ci && npm run build`
}
