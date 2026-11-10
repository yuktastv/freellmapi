import { describe, it, expect } from 'vitest';
import { IpWindowTracker, createProxyRateLimiter, createAdminRateLimiter, rateLimitKey } from '../../middleware/rateLimit.js';

const WINDOW_MS = 60_000;

function fakeReq(ip: string) {
  return { ip, socket: { remoteAddress: ip } } as any;
}

function fakeRes() {
  const res: any = { statusCode: 200, headers: {} as Record<string, string> };
  res.setHeader = (k: string, v: string) => { res.headers[k.toLowerCase()] = v; };
  res.status = (code: number) => { res.statusCode = code; return res; };
  res.json = () => res;
  return res;
}

describe('IpWindowTracker', () => {
  it('counts per IP within a window and restarts after it', () => {
    const t = new IpWindowTracker(10);
    expect(t.hit('a', 0).count).toBe(1);
    expect(t.hit('a', 1).count).toBe(2);
    expect(t.hit('a', WINDOW_MS).count).toBe(1);
  });

  it('never grows past its cap under distributed traffic, even when every window is live', () => {
    const t = new IpWindowTracker(100);
    for (let i = 0; i < 10_000; i++) {
      t.hit(`10.${(i >> 16) & 255}.${(i >> 8) & 255}.${i & 255}`, 1000 + i % 50);
      expect(t.size).toBeLessThanOrEqual(100);
    }
    expect(t.size).toBe(100);
  });

  it('evicts the oldest window first and keeps the newest', () => {
    const t = new IpWindowTracker(3);
    t.hit('a', 0); t.hit('b', 1); t.hit('c', 2); t.hit('d', 3);
    expect(t.size).toBe(3);
    // 'a' was evicted, so it starts a fresh window; 'd' kept its count.
    expect(t.hit('d', 4).count).toBe(2);
    expect(t.hit('a', 5).count).toBe(1);
  });

  it('prunes expired windows without waiting to hit the cap', () => {
    const t = new IpWindowTracker(1000);
    for (let i = 0; i < 500; i++) t.hit(`ip${i}`, i);
    expect(t.size).toBe(500);
    t.hit('late', WINDOW_MS + 250);
    // Windows started at t < 251 have expired; the rest are still live.
    expect(t.size).toBe(500 - 251 + 1);
  });

  it('a restarted window moves to the back, so it is not the next one evicted', () => {
    const t = new IpWindowTracker(2);
    t.hit('a', 0);
    t.hit('b', WINDOW_MS - 1);
    t.hit('a', WINDOW_MS);            // a's window restarts (and b's is still live)
    t.hit('c', WINDOW_MS + 1);        // over the cap: evicts b, the oldest live window
    expect(t.hit('a', WINDOW_MS + 2).count).toBe(2);
    expect(t.hit('b', WINDOW_MS + 3).count).toBe(1);
  });
});

describe.each([
  ['proxy', createProxyRateLimiter],
  ['admin', createAdminRateLimiter],
] as const)('%s rate limiter under a distributed flood (regression)', (_name, create) => {
  // Old behaviour: once more than 10,000 IPs had live windows, EVERY request
  // scanned the whole map and pruned nothing (none had expired), so the map
  // grew without bound and each request got slower. 60,000 distinct IPs used
  // to cost ~2.5 billion map iterations.
  it('stays fast with far more live IPs than the default cap', () => {
    const limiter = create(5);
    const start = performance.now();
    let next = 0;
    for (let i = 0; i < 60_000; i++) {
      limiter(fakeReq(`10.${(i >> 16) & 255}.${(i >> 8) & 255}.${i & 255}`), fakeRes(), () => { next++; });
    }
    expect(next).toBe(60_000);
    expect(performance.now() - start).toBeLessThan(5_000);
  });

  it('still enforces the limit for an IP while other IPs churn the map', () => {
    const limiter = create(3, { maxTrackedIps: 1000 });
    const run = (ip: string) => { const res = fakeRes(); let passed = false; limiter(fakeReq(ip), res, () => { passed = true; }); return { passed, res }; };
    for (let i = 0; i < 3; i++) expect(run('203.0.113.7').passed).toBe(true);
    for (let i = 0; i < 500; i++) run(`10.0.${i >> 8}.${i & 255}`);
    const blocked = run('203.0.113.7');
    expect(blocked.passed).toBe(false);
    expect(blocked.res.statusCode).toBe(429);
    expect(blocked.res.headers['retry-after']).toBeDefined();
  });
});

describe('rateLimitKey', () => {
  it('groups every address in an IPv6 /64 into one bucket', () => {
    const key = rateLimitKey('2001:db8:1:2::1');
    expect(key).toBe('2001:db8:1:2::/64');
    for (const a of ['2001:db8:1:2::ffff', '2001:0db8:0001:0002:aaaa:bbbb:cccc:dddd', '2001:DB8:1:2:0:0:0:9', '2001:db8:1:2::1%eth0']) {
      expect(rateLimitKey(a), a).toBe(key);
    }
  });

  it('keeps different /64s apart', () => {
    expect(rateLimitKey('2001:db8:1:3::1')).not.toBe(rateLimitKey('2001:db8:1:2::1'));
    expect(rateLimitKey('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(rateLimitKey('::1')).toBe('0:0:0:0::/64');
    expect(rateLimitKey('64:ff9b::192.0.2.1')).toBe('64:ff9b:0:0::/64');
  });

  it('counts IPv4-mapped IPv6 as the IPv4 address, and leaves IPv4 and non-IPs alone', () => {
    expect(rateLimitKey('::ffff:203.0.113.7')).toBe('203.0.113.7');
    expect(rateLimitKey('::FFFF:203.0.113.7')).toBe('203.0.113.7');
    expect(rateLimitKey('203.0.113.7')).toBe('203.0.113.7');
    expect(rateLimitKey('unknown')).toBe('unknown');
  });
});

describe.each([
  ['proxy', createProxyRateLimiter],
  ['admin', createAdminRateLimiter],
] as const)('%s rate limiter, IPv6 address rotation (regression)', (_name, create) => {
  const run = (limiter: ReturnType<typeof create>, ip: string) => {
    const res = fakeRes();
    let passed = false;
    limiter(fakeReq(ip), res, () => { passed = true; });
    return { passed, status: res.statusCode };
  };

  // Before: every address in the attacker's /64 got its own fresh window.
  it('limits a client that rotates addresses inside its /64', () => {
    const limiter = create(3);
    for (let i = 1; i <= 3; i++) expect(run(limiter, `2001:db8:1:2::${i.toString(16)}`).passed).toBe(true);
    const fourth = run(limiter, '2001:db8:1:2::beef');
    expect(fourth.passed).toBe(false);
    expect(fourth.status).toBe(429);
  });

  it('does not penalize a neighbouring /64', () => {
    const limiter = create(3);
    for (let i = 1; i <= 4; i++) run(limiter, `2001:db8:1:2::${i}`);
    expect(run(limiter, '2001:db8:1:3::1').passed).toBe(true);
  });

  it('shares one bucket between an IPv4 client and its IPv4-mapped form', () => {
    const limiter = create(2);
    expect(run(limiter, '203.0.113.7').passed).toBe(true);
    expect(run(limiter, '::ffff:203.0.113.7').passed).toBe(true);
    expect(run(limiter, '203.0.113.7').passed).toBe(false);
  });
});
