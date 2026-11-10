import { describe, expect, it } from 'vitest'
import { dockerUpdateCommand, sourceUpdateCommand } from './update-commands'

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

describe('dockerUpdateCommand', () => {
  it('pulls only once .env already pins the new immutable tag, and never edits .env', () => {
    const command = dockerUpdateCommand('abc1234')
    expect(command).toBe(
      "if grep -qx 'FREELLMAPI_IMAGE_TAG=sha-abc1234' .env; then docker compose pull && docker compose up -d; else echo 'Set FREELLMAPI_IMAGE_TAG=sha-abc1234 in .env, then run this again'; fi",
    )
    expect(command).not.toMatch(/sed|>\s*\.env|tee|-i\b/)
  })

  it('falls back to a non-executing hint when the commit is unknown or malformed', () => {
    for (const bad of [undefined, '', 'abc', 'abc1234x', "abc1234'; rm -rf ~; '", 'ABC1234']) {
      const command = dockerUpdateCommand(bad)
      expect(command.startsWith('#'), String(bad)).toBe(true)
      expect(command).toContain('FREELLMAPI_IMAGE_TAG=sha-<commit>')
    }
  })
})
