# Avenbay releases

This public repository distributes signed-version release artifacts for the
Avenbay Fleet worker. Product source code is maintained in a private repository;
this repository intentionally contains no application source.

The auditable installer served by Cloudflare Pages lives in `public/`. The
private release workflow synchronizes only `public/install.sh` and
`public/_headers`; it never publishes Fleet application source.

## Install

On a supported Linux systemd host:

```sh
curl -fsSL https://get.avenbay.com/install.sh | sudo sh
```

Inspect the installer before running it:

```sh
curl -fsSL https://get.avenbay.com/install.sh
```

The installer supports Linux AMD64 and ARM64. It downloads the latest release,
verifies its SHA-256 checksum, creates an unprivileged `fleet` service account,
and installs the worker and its systemd unit.

## Cloudflare Pages

`get.avenbay.com` deploys this repository with:

- Production branch: `main`
- Framework preset: None
- Build command: `exit 0`
- Build output directory: `public`

## Release assets

Each release contains:

- `fleet-worker_linux_amd64.tar.gz`
- `fleet-worker_linux_arm64.tar.gz`
- `checksums.txt`

Release assets are built by GitHub Actions in the private Fleet repository and
published here. No source code or build credentials are included in the assets.

## Security

Do not report security vulnerabilities in a public issue. Contact the Avenbay
maintainers privately through GitHub or the support channel shown in the Avenbay
application.

Copyright Avenbay. All rights reserved. Distribution of these binaries does not
make the Fleet source code open source.
