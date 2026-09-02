# BFE landing page deployment

This repository owns the public landing page independently from the BFE Drive
Web client and Backend.

## Shared VPS

The production HTTPS server exposes the generic local Nginx extension boundary:

```nginx
include /etc/nginx/snippets/bfe-drive.local.d/*.conf;
```

`deploy/nginx/bfe-landing-page.locations.conf` is installed into that boundary
as `/etc/nginx/snippets/bfe-drive.local.d/bfe-landing-page.conf`.

The landing page owns only:

- `/`
- `/styles.css`

The Flutter client independently owns `/sign-in`, `/oauth/callback`, its
application routes and Flutter assets. Backend routes remain Backend-owned.

Required operator environment:

```text
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

The deployment synchronizes only `index.html` and `styles.css` into
`/var/www/bfe-landing-page`, installs the landing-owned Nginx fragment, validates
the complete Nginx configuration and reloads Nginx only after validation
succeeds.
