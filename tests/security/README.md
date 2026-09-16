# Synthetic media security integration checks

Use sibling `backend`, `frontend`, and `devops` checkouts on their security branches.
The stack uses dedicated synthetic MinIO credentials and loopback ports 18882/19090.
It never connects to the production database, provider or buckets.

```sh
docker compose -p rally-security-test -f tests/security/docker-compose.yml up -d --build
python3 tests/security/verify_media_proxy.py
```

The Python check verifies real SigV4 PUT/GET, Range 206, legacy HTML/SVG disposition,
CSP sandbox/nosniff/no-store on 200/206/404/PUT, and the absence of media CSP on the SPA.
It saves synthetic signed URLs to `/tmp/rallytrack-media-urls.json` (one-hour expiry).

For a browser check, replace `__MEDIA_URLS__` in `browser_media_check.js.template`
with that JSON and pass the resulting function to Playwright CLI `run-code`.
Run against Chromium and WebKit. Read `window.securityMediaResult` afterward.
It checks downloads, three simultaneous synthetic MP4 views, seeking, direct-link
playback, and that sandboxed media cannot read app localStorage.
`browser_ui_check.js` checks only the frontend using explicitly mocked API responses;
it validates player-switch cancellation, error-state distinction, and zero direct
Gemini calls. Read `window.securityUiResult` afterward.

These browser mocks are separate from the real backend HTTP/H2/S3-mock contract tests
and the real MinIO proxy test; none proves an actual ML model inference run.
The generated clip is synthetic blue 160×120, one second, ten frames.

```sh
docker compose -p rally-security-test -f tests/security/docker-compose.yml down -v
```
