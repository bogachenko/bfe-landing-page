# BFE landing page deployment

This repository owns the public landing page independently from the BFE Drive
Web client and Backend.

## Public host

The landing page is served from `BFE_LANDING_HOST`. BFE Drive uses the separate
`BFE_PUBLIC_HOST` hostname.

A typical shell configuration is:

```bash
export BFE_LANDING_HOST='webshopstudio.ru'
export BFE_PUBLIC_HOST="drive.${BFE_LANDING_HOST}"
```

The same deployment layout therefore also supports, for example:

```bash
export BFE_LANDING_HOST='any_word.com'
export BFE_PUBLIC_HOST="disk.${BFE_LANDING_HOST}"
```

`BFE_LANDING_HOST` and `BFE_PUBLIC_HOST` are intentionally independent inputs;
the deployment does not attempt to derive the registrable/root domain by
stripping labels from another hostname.

## VPS hosting

The landing deployment owns its complete Nginx vhost at:

```text
/etc/nginx/conf.d/bfe-landing-page.conf
```

It does not use the BFE Drive local-extension directory and does not modify the
Backend-owned `bfe-drive.conf`.

The deployment:

- synchronizes `index.html` and `styles.css` to `/var/www/bfe-landing-page`;
- removes the legacy landing fragment from the Drive vhost when present;
- provisions the `BFE_LANDING_HOST` Let's Encrypt certificate through HTTP-01
  webroot validation when no valid certificate exists;
- installs the landing-owned HTTP/HTTPS Nginx vhost;
- validates Nginx before reload;
- installs a renewal reload hook that remains usable if the landing page is
  later moved to a standalone VPS.

Required operator environment:

```text
BFE_LANDING_HOST
BFE_ACME_EMAIL
BFE_VPS_SSH_TARGET
```

Optional when SSH key authentication is used:

```text
BFE_VPS_SSH_IDENTITY_FILE
```

Deploy from the repository root with:

```bash
make deploy-real
```

The DNS A/AAAA records for `BFE_LANDING_HOST` must already resolve to the target
VPS before first certificate issuance.
