#!/usr/bin/env bash
# Runs on rust-api-prod through IAP. The first argument is an asset directory
# containing the checked-in config and operational files.
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || { echo 'must run as root' >&2; exit 1; }
assets=${1:?usage: gce-bootstrap.sh ASSET_DIRECTORY}
[[ -d $assets ]] || { echo "asset directory does not exist: $assets" >&2; exit 1; }
operator_user=${SUDO_USER:-}
[[ -n $operator_user && $operator_user != deploy && $operator_user != rustapi ]] || {
  echo 'bootstrap must be invoked through sudo by an operator account' >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends caddy ca-certificates curl ufw

id -u deploy >/dev/null 2>&1 || adduser --disabled-password --gecos '' deploy
id -u rustapi >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin rustapi

install -d -m 0700 -o deploy -g deploy /home/deploy/incoming
install -d -m 0755 -o root -g root /opt/rust-api/releases /etc/rust-api
install -m 0600 -o root -g root "$assets/app.env.example" /etc/rust-api/app.env
install -m 0644 -o root -g root "$assets/rust-api.service" /etc/systemd/system/rust-api.service
install -m 0755 -o root -g root "$assets/rust-api-activate" /usr/local/sbin/rust-api-activate
install -m 0644 -o root -g root "$assets/Caddyfile" /etc/caddy/Caddyfile

printf '%s\n' 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate' \
  >/etc/sudoers.d/rust-api-deploy
chmod 0440 /etc/sudoers.d/rust-api-deploy
printf '%s ALL=(root) NOPASSWD: ALL\n' "$operator_user" >/etc/sudoers.d/rust-api-operator
chmod 0440 /etc/sudoers.d/rust-api-operator
# The Google guest agent adds metadata-SSH users to this group. Disable its
# broad sudo grant; operators and the deploy user have explicit rules above.
if [[ -f /etc/sudoers.d/google_sudoers ]]; then
  sed -i 's/^%google-sudoers /# %google-sudoers disabled: /' /etc/sudoers.d/google_sudoers
fi
gpasswd -d deploy google-sudoers >/dev/null 2>&1 || true
visudo -cf /etc/sudoers.d/rust-api-deploy
visudo -cf /etc/sudoers.d/rust-api-operator
caddy validate --config /etc/caddy/Caddyfile

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw logging off
ufw allow from 35.235.240.0/20 to any port 22 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable rust-api caddy
# Do not expose the default Caddy site or request a certificate until the AAAA
# record is published. The operator starts it with gce-enable-caddy.sh.
systemctl stop rust-api caddy || true
