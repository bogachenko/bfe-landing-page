#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_SOURCE="$SCRIPT_DIR/nginx/bfe-landing-page.locations.conf"
REMOTE_WEB_ROOT="/var/www/bfe-landing-page"
REMOTE_NGINX_DIR="/etc/nginx/snippets/bfe-drive.local.d"
REMOTE_NGINX_FILE="$REMOTE_NGINX_DIR/bfe-landing-page.conf"

: "${BFE_VPS_SSH_TARGET:?set BFE_VPS_SSH_TARGET in the environment}"

for command in ssh rsync; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'ERROR: required command is missing: %s\n' "$command" >&2
    exit 1
  }
done

[[ -s "$REPO_ROOT/index.html" ]] || {
  printf 'ERROR: landing page is missing: %s\n' "$REPO_ROOT/index.html" >&2
  exit 1
}
[[ -s "$REPO_ROOT/styles.css" ]] || {
  printf 'ERROR: landing stylesheet is missing: %s\n' "$REPO_ROOT/styles.css" >&2
  exit 1
}
[[ -s "$NGINX_SOURCE" ]] || {
  printf 'ERROR: landing Nginx source is missing: %s\n' "$NGINX_SOURCE" >&2
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

"${ssh_remote[@]}" 'sudo -n grep -Fq "include /etc/nginx/snippets/bfe-drive.local.d/*.conf;" /etc/nginx/conf.d/bfe-drive.conf' || {
  printf 'ERROR: Backend Nginx local-extension hook is not active on the target VPS\n' >&2
  exit 1
}

"${ssh_remote[@]}" 'set -eu
user_name="$(id -un)"
group_name="$(id -gn)"
sudo -n install -d -o "$user_name" -g "$group_name" -m 0755 /var/www/bfe-landing-page
sudo -n install -d -o root -g root -m 0755 /etc/nginx/snippets/bfe-drive.local.d
'

rsync -a --delete --delete-excluded \
  --include='/index.html' \
  --include='/styles.css' \
  --exclude='*' \
  -e "$rsync_ssh" \
  "$REPO_ROOT/" \
  "$BFE_VPS_SSH_TARGET:$REMOTE_WEB_ROOT/"

remote_tmp="/tmp/bfe-landing-page.locations.$$"
rsync -a -e "$rsync_ssh" "$NGINX_SOURCE" "$BFE_VPS_SSH_TARGET:$remote_tmp"

"${ssh_remote[@]}" "set -euo pipefail
source_file='$remote_tmp'
target_file='$REMOTE_NGINX_FILE'
backup_file=''
cleanup() {
  rm -f \"\$source_file\"
  if [[ -n \"\$backup_file\" ]]; then
    rm -f \"\$backup_file\"
  fi
}
trap cleanup EXIT

if sudo -n test -f \"\$target_file\"; then
  backup_file=\"\$(mktemp)\"
  sudo -n cp \"\$target_file\" \"\$backup_file\"
fi

sudo -n install -o root -g root -m 0644 \"\$source_file\" \"\$target_file\"
if ! sudo -n nginx -t; then
  if [[ -n \"\$backup_file\" ]]; then
    sudo -n install -o root -g root -m 0644 \"\$backup_file\" \"\$target_file\"
  else
    sudo -n rm -f \"\$target_file\"
  fi
  sudo -n nginx -t >/dev/null 2>&1 || true
  exit 1
fi

sudo -n systemctl reload nginx
sudo -n systemctl is-active --quiet nginx
"

printf 'BFE landing page shared-VPS deployment: OK\n'
