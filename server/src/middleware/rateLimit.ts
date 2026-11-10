import net from 'node:net';
import type { Request, Response, NextFunction } from 'express';

// Per-IP fixed-window rate limiter for the public /v1 proxy (#35, item #6).
//
// The /v1 surface authenticates with the unified API key but has no password
// login like the dashboard does, so without this an attacker who can reach the
// server could brute-force the key or flood upstream providers. This caps how
// many requests a single client IP can make per minute and returns a standard
// OpenAI-shaped 429 once the cap is exceeded.
//
// FreeLLMAPI is a single-user tool, so the default ceiling is generous. Tune it
// with PROXY_RATE_LIMIT_RPM (requests per minute per IP); set it to 0 to turn
// rate limiting off entirely.

const WINDOW_MS = 60_000;
const DEFAULT_RPM = 120;
// Bound the IP map so a flood of distinct (e.g. spoofed) source addresses can't
// grow it without limit (see IpWindowTracker).
const MAX_TRACKED_IPS = 10_000;

interface WindowState {
  count: number;
  resetAt: number;
}

export interface RateLimiterOptions {
  /** Cap on tracked client IPs. Default MAX_TRACKED_IPS. */
  maxTrackedIps?: number;
}

/**
 * Per-IP fixed windows with a hard size bound.
 *
 * Every window lasts WINDOW_MS, and an entry is (re)inserted at the end of the
 * Map whenever its window starts. Map iteration follows insertion order, so the
 * entries are always sorted by resetAt, oldest first. That gives:
 *  - expiry pruning that pops from the front and stops at the first live
 *    window: amortized O(1) per request, instead of a full scan once the map
 *    is large (which used to run on EVERY request while it was over the cap);
 *  - a hard cap: if a distributed flood keeps more than `maxTracked` windows
 *    live, the oldest live window is evicted. The map can never grow past the
 *    cap. Eviction only forgets a count (that IP starts a fresh window), so it
 *    can never block a request that would otherwise have been allowed.
 */
export class IpWindowTracker {
  private readonly windows = new Map<string, WindowState>();

  constructor(private readonly maxTracked: number = MAX_TRACKED_IPS) {}

  get size(): number {
    return this.windows.size;
  }

  /** Count one request for `ip` and return its current window. */
  hit(ip: string, now: number): WindowState {
    this.pruneExpired(now);
    let state = this.windows.get(ip);
    if (!state || now >= state.resetAt) {
      // Delete before set so a restarted window moves to the end and the
      // insertion order stays sorted by resetAt.
      this.windows.delete(ip);
      state = { count: 0, resetAt: now + WINDOW_MS };
      this.windows.set(ip, state);
      while (this.windows.size > this.maxTracked) {
        const oldest = this.windows.keys().next().value as string;
        this.windows.delete(oldest);
      }
    }
    state.count += 1;
    return state;
  }

  private pruneExpired(now: number): void {
    for (const [key, value] of this.windows) {
      if (now < value.resetAt) break;
      this.windows.delete(key);
    }
  }
}

/**
 * The bucket a client address is counted in.
 *
 * IPv6 clients are grouped by their /64. A /64 is the smallest prefix an ISP
 * or cloud provider hands to one subscriber or one host, and its owner can use
 * every one of its 2^64 addresses, so a per-address count lets a single
 * attacker rotate addresses and never hit the limit. IPv4-mapped IPv6
 * (::ffff:1.2.3.4) counts as the IPv4 address, so a dual-stack socket cannot
 * give one client two buckets. Anything that is not an IP is used as-is.
 */
export function rateLimitKey(ip: string): string {
  let addr = ip.trim().toLowerCase();
  const zone = addr.indexOf('%');
  if (zone !== -1) addr = addr.slice(0, zone);
  if (addr.startsWith('::ffff:') && net.isIPv4(addr.slice(7))) return addr.slice(7);
  if (!net.isIPv6(addr)) return addr;
  return `${ipv6Prefix64(addr)}::/64`;
}

/** First four hextets of a valid IPv6 address, normalized (no leading zeros). */
function ipv6Prefix64(addr: string): string {
  let text = addr;
  // An embedded IPv4 tail ("::1.2.3.4") becomes its two hextets.
  const lastColon = text.lastIndexOf(':');
  const tail = text.slice(lastColon + 1);
  if (tail.includes('.')) {
    const o = tail.split('.').map(Number) as [number, number, number, number];
    text = `${text.slice(0, lastColon + 1)}${((o[0] << 8) | o[1]).toString(16)}:${((o[2] << 8) | o[3]).toString(16)}`;
  }
  const [head, rest] = text.split('::') as [string, string | undefined];
  const headGroups = head ? head.split(':') : [];
  const tailGroups = rest ? rest.split(':') : [];
  const groups = rest === undefined
    ? headGroups
    : [...headGroups, ...Array(8 - headGroups.length - tailGroups.length).fill('0'), ...tailGroups];
  return groups.slice(0, 4).map(g => parseInt(g, 16).toString(16)).join(':');
}

function parseLimit(): number {
  const raw = process.env.PROXY_RATE_LIMIT_RPM;
  if (raw === undefined || raw.trim() === '') return DEFAULT_RPM;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return DEFAULT_RPM;
  return Math.floor(n);
}

export function createProxyRateLimiter(rpmLimit?: number, options: RateLimiterOptions = {}) {
  const limit = rpmLimit !== undefined ? Math.floor(Math.max(0, rpmLimit)) : parseLimit();
  const windows = new IpWindowTracker(options.maxTrackedIps);

  return function proxyRateLimit(req: Request, res: Response, next: NextFunction): void {
    if (limit === 0) {
      next();
      return;
    }

    const now = Date.now();
    const ip = req.ip ?? req.socket.remoteAddress ?? 'unknown';

    const state = windows.hit(rateLimitKey(ip), now);

    res.setHeader('X-RateLimit-Limit', String(limit));
    res.setHeader('X-RateLimit-Remaining', String(Math.max(0, limit - state.count)));
    res.setHeader('X-RateLimit-Reset', String(Math.ceil(state.resetAt / 1000)));

    if (state.count > limit) {
      const retryAfter = Math.max(1, Math.ceil((state.resetAt - now) / 1000));
      res.setHeader('Retry-After', String(retryAfter));
      res.status(429).json({
        error: {
          message: `Rate limit exceeded: more than ${limit} requests per minute. Retry in ${retryAfter}s.`,
          type: 'rate_limit_error',
        },
      });
      return;
    }

    next();
  };
}

// Per-IP fixed-window rate limiter for the /api/* admin surface.
//
// This is a flood guard, not the brute-force guard: dashboard login already has
// its own per-email lockout (routes/auth.ts), and the one admin endpoint that
// verifies a password — GET /api/keys/export — gets its own much tighter
// limiter mounted in app.ts. The broad cap therefore has to clear normal
// dashboard traffic with room to spare. Opening the dashboard fans out across
// keys, health, models, analytics, settings and profiles, and several of those
// poll, so a single user legitimately spends dozens of requests a minute.
//
// Tune with ADMIN_RATE_LIMIT_RPM (requests per minute per IP); 0 disables it.
const ADMIN_DEFAULT_RPM = 600;

function parseAdminLimit(): number {
  const raw = process.env.ADMIN_RATE_LIMIT_RPM;
  if (raw === undefined || raw.trim() === '') return ADMIN_DEFAULT_RPM;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return ADMIN_DEFAULT_RPM;
  return Math.floor(n);
}

export function createAdminRateLimiter(rpm?: number, options: RateLimiterOptions = {}) {
  const limit = rpm !== undefined ? Math.floor(Math.max(0, rpm)) : parseAdminLimit();
  const windows = new IpWindowTracker(options.maxTrackedIps);

  return function adminRateLimit(req: Request, res: Response, next: NextFunction): void {
    if (limit === 0) {
      next();
      return;
    }

    const now = Date.now();
    const ip = req.ip ?? req.socket.remoteAddress ?? 'unknown';

    const state = windows.hit(rateLimitKey(ip), now);

    res.setHeader('X-RateLimit-Limit', String(limit));
    res.setHeader('X-RateLimit-Remaining', String(Math.max(0, limit - state.count)));
    res.setHeader('X-RateLimit-Reset', String(Math.ceil(state.resetAt / 1000)));

    if (state.count > limit) {
      const retryAfter = Math.max(1, Math.ceil((state.resetAt - now) / 1000));
      res.setHeader('Retry-After', String(retryAfter));
      res.status(429).json({
        error: {
          message: `Rate limit exceeded: more than ${limit} requests per minute. Retry in ${retryAfter}s.`,
          type: 'rate_limit_error',
        },
      });
      return;
    }

    next();
  };
}
