# Changelog

## 1.0.0 - 2026-08-10

First release.

- Any number of Plausible servers, each with its own base URL and stats API key.
- Sites you add by their site ID, each listed with a visitor count and a sparkline.
- Dashboard with visitors, pageviews, bounce rate and visit duration, a visitors-over-time chart,
  and ranges from a single day out to 12 months or a custom pair of dates.
- Breakdowns by page, source, country and device, with a switch between device type, browser and OS.
- Live visitor count that polls every 30 seconds while the dashboard is open.
- Support for servers old enough to only speak the v1 stats API. The app probes for the version once
  and remembers it.
- Per-server SOCKS5 proxy, so servers reachable only through Tor work with Orbot.
- Light and dark themes.
