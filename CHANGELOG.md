# Changelog

## [1.4.0](https://github.com/cheesymoon/drausible/compare/v1.3.3...v1.4.0) (2026-08-26)


### Features

* warn before saving a server that talks plain http ([32bf4a5](https://github.com/cheesymoon/drausible/commit/32bf4a534e9cc042e9ffda8c674daa9a1d55ac0d))

## [1.3.3](https://github.com/cheesymoon/drausible/compare/v1.3.2...v1.3.3) (2026-08-23)


* Remove Play Store packaging data from the APK.

## [1.3.2](https://github.com/cheesymoon/drausible/compare/v1.3.1...v1.3.2) (2026-08-15)


* Rewrite the F-Droid listing text. The app itself is unchanged

## [1.3.1](https://github.com/cheesymoon/drausible/compare/v1.3.0...v1.3.1) (2026-08-13)


* Push Drausible to F-Droid. Same signature there and on the GitHub release
* Shrink the downloadable binary size: split builds by processor kind

## [1.3.0](https://github.com/cheesymoon/drausible/compare/v1.2.0...v1.3.0) (2026-08-13)

* Push Drausible to F-Droid. Same signature there and on the GitHub release
* Shrink the downloadable binary size: split builds by processor kind

## [1.2.0](https://github.com/cheesymoon/drausible/compare/v1.1.0...v1.2.0) (2026-08-13)


### Features

* **backup:** carry a config between devices without exposing the keys ([0594e8f](https://github.com/cheesymoon/drausible/commit/0594e8f852e30e4c882d859e7dab028ff1eb3f81))
* **sites:** pull the site list to refresh it ([08d5af5](https://github.com/cheesymoon/drausible/commit/08d5af53a1585b4ace667a254fa234f534c87048))

## [1.1.0](https://github.com/cheesymoon/drausible/compare/v1.0.0...v1.1.0) (2026-08-11)


- Visits and views per visit on the dashboard, next to the metrics that were
  already there.
- Servers too old to report those two keep working. The request falls back to
  the four metrics v1 has always had, and the dashboard leaves the two cards out
  rather than showing a zero it made up.

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
