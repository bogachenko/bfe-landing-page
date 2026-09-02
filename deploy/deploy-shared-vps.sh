#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_ACME_SOURCE="$SCRIPT_DIR/nginx/bfe-landing-page.acme.conf"
NGINX_FINAL_SOURCE="$SCRIPT_DIR/nginx/bfe-landing-page.conf"
CERTBOT_HOOK_SOURCE="$SCRIPT_DIR/certbot/30-bfe-landing-page-nginx"
REMOTE_WEB_ROOT="/var/www/bfe-landing-page"

: "${BFE_VPS_SSH_TARGET:?set BFE_VPS_SSH_TARGET in the environment}"
: "${BFE_LANDING_HOST:?set BFE_LANDING_HOST in the environment}"
: "${BFE_PUBLIC_HOST:?set BFE_PUBLIC_HOST in the environment}"
: "${BFE_ACME_EMAIL:?set BFE_ACME_EMAIL in the environment}"

for command in ssh rsync python3 sed mktemp grep cp; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'ERROR: required command is missing: %s\n' "$command" >&2
    exit 1
  }
done

BFE_LANDING_HOST_CANONICAL="$(python3 - "$BFE_LANDING_HOST" <<'PY'
import re, sys
host = sys.argv[1]
if not host or any(ch.isspace() for ch in host) or "://" in host or "/" in host or ":" in host:
    raise SystemExit(1)
try:
    host = host.encode("idna").decode("ascii").lower().rstrip(".")
except UnicodeError:
    raise SystemExit(1)
if len(host) > 253 or "." not in host:
    raise SystemExit(1)
for label in host.split("."):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
        raise SystemExit(1)
print(host)
PY
)" || {
  printf 'ERROR: invalid BFE_LANDING_HOST\n' >&2
  exit 1
}

BFE_PUBLIC_HOST_CANONICAL="$(python3 - "$BFE_PUBLIC_HOST" <<'PY'
import re, sys
host = sys.argv[1]
if not host or any(ch.isspace() for ch in host) or "://" in host or "/" in host or ":" in host:
    raise SystemExit(1)
try:
    host = host.encode("idna").decode("ascii").lower().rstrip(".")
except UnicodeError:
    raise SystemExit(1)
if len(host) > 253 or "." not in host:
    raise SystemExit(1)
for label in host.split("."):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
        raise SystemExit(1)
print(host)
PY
)" || {
  printf 'ERROR: invalid BFE_PUBLIC_HOST\n' >&2
  exit 1
}

[[ "$BFE_LANDING_HOST_CANONICAL" != "$BFE_PUBLIC_HOST_CANONICAL" ]] || {
  printf 'ERROR: BFE_LANDING_HOST and BFE_PUBLIC_HOST must be different hosts\n' >&2
  exit 1
}

BFE_ACME_EMAIL_CANONICAL="$(python3 - "$BFE_ACME_EMAIL" <<'PY'
import re, sys
value = sys.argv[1]
if not value or any(ch.isspace() for ch in value) or value.count("@") != 1:
    raise SystemExit(1)
local, domain = value.rsplit("@", 1)
if not re.fullmatch(r"[A-Za-z0-9.!#$%&+*/=?^_{}|~-]+", local):
    raise SystemExit(1)
try:
    domain = domain.encode("idna").decode("ascii").lower().rstrip(".")
except UnicodeError:
    raise SystemExit(1)
if len(local.encode()) > 64 or len(domain) > 253 or "." not in domain:
    raise SystemExit(1)
for label in domain.split("."):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
        raise SystemExit(1)
print(f"{local}@{domain}")
PY
)" || {
  printf 'ERROR: invalid BFE_ACME_EMAIL\n' >&2
  exit 1
}

for path in \
  "$REPO_ROOT/index.html" \
  "$REPO_ROOT/styles.css" \
  "$NGINX_ACME_SOURCE" \
  "$NGINX_FINAL_SOURCE" \
  "$CERTBOT_HOOK_SOURCE"; do
  [[ -s "$path" ]] || {
    printf 'ERROR: required deployment source is missing: %s\n' "$path" >&2
    exit 1
  }
done

grep -Fq 'href="https://__BFE_PUBLIC_HOST__/sign-in"' "$REPO_ROOT/index.html" || {
  printf 'ERROR: landing Drive link template is missing from index.html\n' >&2
  exit 1
}

ssh_args=(-o IdentitiesOnly=yes)
if [[ -n "${BFE_VPS_SSH_IDENTITY_FILE:-}" ]]; then
  [[ "$BFE_VPS_SSH_IDENTITY_FILE" = /* && -r "$BFE_VPS_SSH_IDENTITY_FILE" ]] || {
    printf 'ERROR: BFE_VPS_SSH_IDENTITY_FILE must be an absolute readable file\n' >&2
    exit 1
  }
  ssh_args+=(-i "$BFE_VPS_SSH_IDENTITY_FILE")
else
  ssh_args+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive)
fi

ssh_remote=(ssh "${ssh_args[@]}" "$BFE_VPS_SSH_TARGET")
printf -v rsync_ssh '%q ' ssh "${ssh_args[@]}"

"${ssh_remote[@]}" 'set -eu
user_name="$(id -un)"
group_name="$(id -gn)"
sudo -n install -d -o "$user_name" -g "$group_name" -m 0755 /var/www/bfe-landing-page
sudo -n install -d -o root -g root -m 0755 /etc/nginx/conf.d
sudo -n install -d -o root -g root -m 0755 /var/lib/letsencrypt
sudo -n install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
'

local_tmp="$(mktemp -d)"
cleanup_local() {
  rm -rf "$local_tmp"
}
trap cleanup_local EXIT

sed "s/__BFE_PUBLIC_HOST__/$BFE_PUBLIC_HOST_CANONICAL/g" \
  "$REPO_ROOT/index.html" > "$local_tmp/index.html"
cp "$REPO_ROOT/styles.css" "$local_tmp/styles.css"

rsync -a --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --delete --delete-excluded \
  --include='/index.html' \
  --include='/styles.css' \
  --exclude='*' \
  -e "$rsync_ssh" \
  "$local_tmp/" \
  "$BFE_VPS_SSH_TARGET:$REMOTE_WEB_ROOT/"

sed "s/__BFE_LANDING_HOST__/$BFE_LANDING_HOST_CANONICAL/g" \
  "$NGINX_ACME_SOURCE" > "$local_tmp/acme.conf"
sed "s/__BFE_LANDING_HOST__/$BFE_LANDING_HOST_CANONICAL/g" \
  "$NGINX_FINAL_SOURCE" > "$local_tmp/final.conf"
sed "s/__BFE_LANDING_HOST__/$BFE_LANDING_HOST_CANONICAL/g" \
  "$CERTBOT_HOOK_SOURCE" > "$local_tmp/certbot-hook"

remote_token="$$"
remote_acme="/tmp/bfe-landing-page.acme.$remote_token"
remote_final="/tmp/bfe-landing-page.final.$remote_token"
remote_hook="/tmp/bfe-landing-page.certbot-hook.$remote_token"
rsync -a -e "$rsync_ssh" "$local_tmp/acme.conf" "$BFE_VPS_SSH_TARGET:$remote_acme"
rsync -a -e "$rsync_ssh" "$local_tmp/final.conf" "$BFE_VPS_SSH_TARGET:$remote_final"
rsync -a -e "$rsync_ssh" "$local_tmp/certbot-hook" "$BFE_VPS_SSH_TARGET:$remote_hook"

"${ssh_remote[@]}" "exec sudo -n env \
BFE_LANDING_HOST='$BFE_LANDING_HOST_CANONICAL' \
BFE_ACME_EMAIL='$BFE_ACME_EMAIL_CANONICAL' \
REMOTE_ACME='$remote_acme' \
REMOTE_FINAL='$remote_final' \
REMOTE_HOOK='$remote_hook' \
bash -s" <<'REMOTE'
set -euo pipefail

target_file=/etc/nginx/conf.d/bfe-landing-page.conf
legacy_file=/etc/nginx/snippets/bfe-drive.local.d/bfe-landing-page.conf
hook_file=/etc/letsencrypt/renewal-hooks/deploy/30-bfe-landing-page-nginx
target_backup="$(mktemp)"
legacy_backup="$(mktemp)"
hook_backup="$(mktemp)"
had_target=0
had_legacy=0
had_hook=0
committed=0

if test -f "$target_file"; then
  cp "$target_file" "$target_backup"
  had_target=1
fi
if test -f "$legacy_file"; then
  cp "$legacy_file" "$legacy_backup"
  had_legacy=1
fi
if test -f "$hook_file"; then
  cp "$hook_file" "$hook_backup"
  had_hook=1
fi

rollback() {
  if [[ "$had_target" -eq 1 ]]; then
    install -o root -g root -m 0644 "$target_backup" "$target_file"
  else
    rm -f "$target_file"
  fi
  if [[ "$had_legacy" -eq 1 ]]; then
    install -d -o root -g root -m 0755 "$(dirname "$legacy_file")"
    install -o root -g root -m 0644 "$legacy_backup" "$legacy_file"
  else
    rm -f "$legacy_file"
  fi
  if [[ "$had_hook" -eq 1 ]]; then
    install -o root -g root -m 0755 "$hook_backup" "$hook_file"
  else
    rm -f "$hook_file"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
}

finish() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$committed" -ne 1 ]]; then
    rollback
  fi
  rm -f "$REMOTE_ACME" "$REMOTE_FINAL" "$REMOTE_HOOK" \
    "$target_backup" "$legacy_backup" "$hook_backup"
  exit "$status"
}
trap finish EXIT

# Migrate away from the earlier incorrect design where landing locations were
# injected into the BFE Drive vhost.
rm -f "$legacy_file"

validate_certificate() {
  cert="/etc/letsencrypt/live/$BFE_LANDING_HOST/cert.pem"
  key="/etc/letsencrypt/live/$BFE_LANDING_HOST/privkey.pem"
  test -s "$cert" && test -s "$key" &&
    openssl x509 -in "$cert" -noout -checkhost "$BFE_LANDING_HOST" >/dev/null 2>&1 &&
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 &&
    openssl pkey -in "$key" -noout >/dev/null 2>&1
}

if ! validate_certificate; then
  if test -e "/etc/letsencrypt/renewal/$BFE_LANDING_HOST.conf" || \
     test -e "/etc/letsencrypt/live/$BFE_LANDING_HOST"; then
    printf 'ERROR: existing Certbot lineage for %s is incomplete or invalid\n' "$BFE_LANDING_HOST" >&2
    exit 1
  fi

  install -o root -g root -m 0644 "$REMOTE_ACME" "$target_file"
  nginx -t
  systemctl reload nginx
  systemctl is-active --quiet nginx

  test -x /snap/bin/certbot || {
    printf 'ERROR: /snap/bin/certbot is not installed on the target VPS\n' >&2
    exit 1
  }

  /snap/bin/certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$BFE_ACME_EMAIL" \
    --webroot \
    --webroot-path /var/lib/letsencrypt \
    --preferred-challenges http \
    --cert-name "$BFE_LANDING_HOST" \
    --key-type ecdsa \
    --elliptic-curve secp256r1 \
    -d "$BFE_LANDING_HOST"

  validate_certificate || {
    printf 'ERROR: landing certificate validation failed after issuance\n' >&2
    exit 1
  }
fi

install -o root -g root -m 0755 "$REMOTE_HOOK" "$hook_file"
install -o root -g root -m 0644 "$REMOTE_FINAL" "$target_file"
nginx -t
systemctl reload nginx
systemctl is-active --quiet nginx
committed=1
REMOTE

printf 'BFE landing page deployment: OK (%s)\n' "$BFE_LANDING_HOST_CANONICAL"
