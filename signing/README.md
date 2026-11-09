# Signing identities

`development.p12` and `development-password.txt` are deliberately shared test credentials. Both Macs import this same identity; never regenerate it per build. They are only for `com.metepolat.Remarc.dev`.

Production certificate and private key are stored exclusively in GitHub Actions Secrets (`REMARC_SIGNING_P12_BASE64`, `REMARC_SIGNING_P12_PASSWORD`). The public fingerprint is pinned in `identities.json`. Production uses a newly created fixed identity. The first installation needs new permissions; future versions retain this identity.

`python3 scripts/sign-app.py /absolute/path/to/app --channel development` signs local test apps. Use `--verify-only` to check either channel without accessing private keys. Production signing requires Actions and never falls back to ad-hoc signing.
