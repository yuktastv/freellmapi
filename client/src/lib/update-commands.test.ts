import { describe, expect, it } from 'vitest'
import { sourceUpdateCommand } from './update-commands'

describe('sourceUpdateCommand', () => {
  it('fetches from the repository the server compared against', () => {
    expect(sourceUpdateCommand('example-org/freellmapi')).toBe(
      'git fetch https://github.com/example-org/freellmapi.git main && git merge --ff-only FETCH_HEAD && npm ci && npm run build',
    )
  })

  it('defaults to this fork, never upstream', () => {
    expect(sourceUpdateCommand()).toContain('https://github.com/yuktastv/freellmapi.git')
    expect(sourceUpdateCommand()).not.toContain('tashfeenahmed')
  })

  it('never interpolates a value that is not owner/name into the shell command', () => {
    for (const bad of ['x/y; rm -rf ~', 'x/$(id)', 'a/b/c', '../x', 'x/y && curl evil', '']) {
      expect(sourceUpdateCommand(bad), bad).toContain('https://github.com/yuktastv/freellmapi.git')
    }
  })
})
