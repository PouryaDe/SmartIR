# IR SmartLink - Agent Guide & Operational Specifications

This document establishes the architecture, network behaviors, security guidelines, and development runbooks for AI agents working on the **IR SmartLink** project.

---

## 1. Project Overview & Role

**IR SmartLink** is a lightweight, ultra-high-performance subscription bridge and reverse proxy deployed on Iranian edge servers. It serves as a resilient intermediary between VPN clients inside Iran and upstream management panels (such as XPanel or Marzban) located on international servers.

### Primary Responsibilities:
1. **Network Resilience & Latency**: Bypass Iranian internet disruptions, packet filtering, and IPv6 blackholes.
2. **Rate Limiting Mitigation**: Forward authenticated real client IPs upstream (`X-Real-IP`, `X-Forwarded-For`) so that hundreds of simultaneous Iranian clients do not cause the SmartLink server IP to be rate-limited (HTTP 429).
3. **Client Configuration Protection**: Prevent VPN client apps (Happ, Streisand, v2rayNG, Sing-box, Clash, Hiddify, NekoBox, Shadowrocket, etc.) from accidentally wiping user proxies when temporary upstream outages or filtering spikes occur.
4. **Unicode & Persian remark safety**: Ensure Persian characters in subscription titles and node remarks do not get corrupted into `??????`.

---

## 2. Key Architecture & File Map

- **`index.php`**: Core engine handling routing, client IP resolution, upstream JSON fetching with stale-if-error caching, header formatting, config normalization, and HTML fallback redirects.
- **`Route.php`**: Fast, lightweight regex routing class without external framework bloat.
- **`config.php`**: Local configuration file defining `API_DOMAIN`, `APP_DEBUG`, and optional `PROXY_URL`.
- **`install.sh`**: One-click production installer for Ubuntu/Debian configuring Nginx, PHP 8.1 FPM, Let's Encrypt SSL, and Linux kernel sysctl network tunings.
- **`cache/`**: Ephemeral disk storage for hashed subscription JSON responses.
- **`tests/`**: PHPUnit test suite validating all core behaviors, edge cases, and regressions.

---

## 3. Core Behaviors & Critical Rules

### A. Network Connection Hierarchy
- **Attempt 1: Direct IPv4 First** (`connect_timeout = 4s`, `timeout = 7s`):
  Iranian datacenters often suffer from 5-second blackhole timeouts when attempting international IPv6 routing. Prioritizing IPv4 direct connection ensures sub-200ms responses under normal conditions.
- **Attempt 2: Fallback Route**:
  - If `PROXY_URL` is defined in `config.php`: Fall back to the configured upstream proxy (SOCKS5 hostname resolution or HTTP proxy) with `connect_timeout = 5s`, `timeout = 10s`.
  - If `PROXY_URL` is empty: Fall back to direct IPv6 (`CURL_IPRESOLVE_V6`).

### B. Client IP Resolution & Anti-Spoofing
- **Cloudflare**: If `HTTP_CF_CONNECTING_IP` is present, it is trusted and extracted.
- **Direct Public Client**: If `REMOTE_ADDR` is a valid public IP, it represents the physical TCP connection from the user's mobile/home network and **MUST** take precedence over client-supplied headers (prevents IP spoofing via arbitrary `X-Forwarded-For`).
- **Internal / Docker Proxy**: If `REMOTE_ADDR` is private/loopback, the first valid IP from `HTTP_X_FORWARDED_FOR` is extracted.
- Extracted IP is forwarded to upstream in `X-Forwarded-For` and `X-Real-IP`.

### C. Stale-if-Error Cache Policy
- **Fresh Cache Lifetime**: 300 seconds (5 minutes). Within this window, responses are served directly from disk without outbound requests.
- **Stale Cache Retention**: 86400 seconds (24 hours). If upstream API requests fail due to filtering, timeouts, or server errors, stale cache is served to ensure uninterrupted connectivity.
- **Garbage Collection**: Probabilistic (5% on requests), unlinks cache files older than 24 hours.

### D. Upstream Outage & VPN App Protection
- When an upstream fetch fails completely and no cache exists:
  - **VPN Clients & API Consumers**: **MUST return HTTP 502 Bad Gateway**. VPN apps treat 502 as a temporary network failure and preserve existing working proxies. Returning HTTP 200 with empty configs causes apps to delete all stored servers.
  - **Genuine Web Browsers**: Return HTML redirect with 0-second meta-refresh and JS redirect to the panel web URL.

---

## 4. Verification & Testing Runbook

Before committing any changes, the agent must execute and verify:

```bash
# 1. Run PHPUnit test suite
./vendor/bin/phpunit

# 2. Verify PHP syntax on modified files
php -l index.php
php -l Route.php
```

All 85+ unit tests must pass cleanly.
