#!/usr/bin/env bash
# One-time setup of the restricted deploy entry point on the production host.
# Creates the `deploy` user whose SSH key (via forced command) can do exactly
# one thing: stream a dist tarball to the pinned deploy script. No shell, no
# scp, no other commands.
#
# Usage (as root):  server-setup.sh "<ssh-ed25519 public key line>"
#
# Re-run any time to refresh the pinned copy of deploy.sh from the production
# branch — updating the deploy logic on the server is a deliberate manual act,
# by design: a compromised GitHub account must not be able to change what runs
# as root here.
set -euo pipefail

PUBKEY=${1:-}
DEPLOY_SH_URL=https://raw.githubusercontent.com/InnovatingOps/mattermost/production/deploy/deploy.sh

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

if ! id deploy >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash deploy
fi

echo "Pinning deploy script from $DEPLOY_SH_URL"
curl -fsSL "$DEPLOY_SH_URL" -o /usr/local/sbin/mattermost-deploy.sh
chown root:root /usr/local/sbin/mattermost-deploy.sh
chmod 755 /usr/local/sbin/mattermost-deploy.sh

cat >/usr/local/sbin/mattermost-deploy <<'EOF'
#!/usr/bin/env bash
# Forced command for the GitHub Actions deploy key (see authorized_keys of
# the `deploy` user). Reads the dist tarball from stdin, takes the release
# name from SSH_ORIGINAL_COMMAND, and runs the pinned deploy script via sudo.
# Anything that isn't a valid release name is rejected.
set -euo pipefail
name=${SSH_ORIGINAL_COMMAND:-}
if ! [[ $name =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    echo "invalid release name: '$name'" >&2
    exit 1
fi
tmp=$(mktemp /tmp/mattermost-dist.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT
cat >"$tmp"
sudo /usr/local/sbin/mattermost-deploy.sh "$tmp" "$name"
EOF
chown root:root /usr/local/sbin/mattermost-deploy
chmod 755 /usr/local/sbin/mattermost-deploy

echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/mattermost-deploy.sh' >/etc/sudoers.d/mattermost-deploy
chmod 440 /etc/sudoers.d/mattermost-deploy
visudo -c >/dev/null

if [ -n "$PUBKEY" ]; then
    install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
    touch /home/deploy/.ssh/authorized_keys
    if ! grep -qF "$PUBKEY" /home/deploy/.ssh/authorized_keys; then
        echo "restrict,command=\"/usr/local/sbin/mattermost-deploy\" $PUBKEY" \
            >>/home/deploy/.ssh/authorized_keys
    fi
    chown deploy:deploy /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
    echo "Deploy key installed (restricted to the forced command)."
else
    echo "No public key given; add one later by re-running with the key as argument."
fi

echo "Done. The CI deploy call is: ssh deploy@<host> '<release-name>' < tarball"
