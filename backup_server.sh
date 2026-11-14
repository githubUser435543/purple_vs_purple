#!/usr/bin/env bash
# Debian 12/13 backup receiver using SSH keys and restricted rsync.
# Run ON THE BACKUP SERVER:
#   sudo bash setup-debian-backup-server.sh /path/to/source.pub [backuprecv]
# Pass a public key, never a private key. Use a different account/key per source.
#
# On the SOURCE machine, generate a dedicated key:
#   sudo install -d -m 700 /root/.ssh
#   sudo ssh-keygen -t ed25519 -f /root/.ssh/backup_ed25519
# Copy only backup_ed25519.pub to the backup server using your admin account.
# The script prints the matching upload and restore commands when finished.
#
# Storage: /srv/backups/ACCOUNT, with one dated subdirectory per upload.
# Metadata: the upload command MUST include -M--fake-super. Original numeric
# ownership, ACLs and privileged xattrs are encoded in rsync user xattrs.
# Restore with rsync as documented below, not cp. No scheduled jobs, retention
# policy, storage quotas, firewall changes or global SSH policy changes are made.
# The upload account can still alter existing data inside its restricted tree;
# these are ordinary backups, not immutable snapshots. Use a separate offline
# copy or server-controlled snapshots when protection from client compromise
# is required. Live databases need application-aware dumps for consistency.

set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage: sudo bash %s PUBLIC_KEY_FILE [ACCOUNT]\n' "${0##*/}"
  printf 'Default account: backuprecv. Requires Debian with systemd and standard SSH Include.\n'
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
[[ $EUID -eq 0 ]] || die 'Run this script with sudo or as root.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian ]] || die 'This script targets Debian.'
[[ -d /run/systemd/system ]] || die 'This script requires systemd running as PID 1.'
[[ -f $1 && -r $1 ]] || die 'The public-key file must be a readable regular file.'

account=${2:-backuprecv}
[[ $account =~ ^[a-z][a-z0-9_-]{0,23}$ ]] || die 'Use a lowercase account name, 1 to 24 characters.'
home_dir="/var/lib/pvp-backup-homes/$account"
data_dir="/srv/backups/$account"
key_file="/etc/ssh/backup-keys/$account"
conf_file="/etc/ssh/sshd_config.d/00-pvp-backup-$account.conf"
state_dir=/var/lib/pvp-backup-setup
marker="$state_dir/$account"

if getent passwd "$account" >/dev/null; then
  [[ -f $marker && ! -L $marker && $(stat -c %u "$marker") == 0 ]] ||
    die "Account $account already exists and was not created by this script. Choose another name."
  IFS=: read -r _ _ account_uid _ _ actual_home actual_shell < <(getent passwd "$account")
  [[ $account_uid -ne 0 && $actual_home == "$home_dir" && $actual_shell == /bin/dash ]] ||
    die 'The managed account has unexpected settings; inspect it before rerunning.'
fi

work_dir=$(mktemp -d /tmp/pvp-backup-setup.XXXXXXXX)
conf_written=0
had_conf=0
key_written=0
had_key=0
committed=0
cleanup() {
  local rc=$?
  if (( key_written && ! committed )); then
    if (( had_key )); then
      cp -p -- "$work_dir/previous.key" "$key_file" || true
    else
      rm -f -- "$key_file" || true
    fi
  fi
  if (( conf_written && ! committed )); then
    if (( had_conf )); then
      cp -p -- "$work_dir/previous.conf" "$conf_file" || true
    else
      rm -f -- "$conf_file" || true
    fi
    # Existing SSH sessions remain open. Restore the previous config on failure.
    if /usr/sbin/sshd -t >/dev/null 2>&1 && systemctl is-active --quiet ssh; then
      systemctl reload ssh || true
    fi
  fi
  rm -rf -- "$work_dir"
  return "$rc"
}
trap cleanup EXIT

# Copy and normalize the key before doing package/account changes. Disallow
# authorized_keys options supplied by callers; this script adds its own.
mapfile -t key_lines < <(awk 'NF && $1 !~ /^#/ { sub(/\r$/, ""); print }' "$1")
[[ ${#key_lines[@]} -eq 1 ]] || die 'Provide exactly one public key.'
read -r key_type key_blob _ <<< "${key_lines[0]}"
case $key_type in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
  *) die 'Expected an ordinary OpenSSH public key without options or certificates.' ;;
esac
printf '%s %s\n' "$key_type" "$key_blob" > "$work_dir/source.pub"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  openssh-server rsync python3
ssh-keygen -l -f "$work_dir/source.pub" >/dev/null || die 'Invalid public key.'
[[ -x /usr/bin/rrsync ]] || die 'The installed rsync package does not provide /usr/bin/rrsync.'

# Keep the ordinary Debian Include in charge. Do not silently rewrite an admin's
# main SSH config or assume that an unused drop-in will protect this account.
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]*(#.*)?)?$' \
  /etc/ssh/sshd_config || die 'Add Include /etc/ssh/sshd_config.d/*.conf to the global SSH config first.'
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
[[ $(/usr/sbin/sshd -T | awk '$1 == "usepam" {print $2}') == yes ]] ||
  die 'This setup expects Debian SSH with UsePAM yes, so locked accounts can use public keys.'

for path in /srv/backups /var/lib/pvp-backup-homes "$home_dir" "$data_dir" \
  /etc/ssh/backup-keys /etc/ssh/sshd_config.d "$key_file" "$conf_file" "$state_dir"; do
  [[ ! -L $path ]] || die "Refusing to manage a symlink: $path"
done
if [[ ! -d /srv/backups ]]; then
  install -d -o root -g root -m 0711 /srv/backups
fi
install -d -o root -g root -m 0755 /var/lib/pvp-backup-homes "$home_dir"
install -d -o root -g root -m 0700 "$state_dir"

if ! getent passwd "$account" >/dev/null; then
  [[ ! -e $data_dir ]] || die "Refusing to take over an existing backup directory: $data_dir"
  # A usable noninteractive shell is required for SSH forced commands. A
  # root-owned home plus dash avoids user-controlled bash startup files.
  useradd --system --user-group --no-create-home --home-dir "$home_dir" \
    --shell /bin/dash "$account"
  printf 'Created by setup-debian-backup-server.sh\n' > "$marker"
fi
passwd -l "$account" >/dev/null
install -d -o "$account" -g "$account" -m 0700 "$data_dir"
runuser -u "$account" -- test -x /srv/backups ||
  die 'The backup account cannot traverse /srv/backups; inspect its permissions.'

# fake-super needs user extended attributes on the actual backup filesystem.
runuser -u "$account" -- /usr/bin/python3 - "$data_dir" <<'PY'
import os
import sys
import tempfile

fd, path = tempfile.mkstemp(prefix=".xattr-check-", dir=sys.argv[1])
try:
    os.setxattr(fd, "user.backup_setup_test", b"ok")
    if os.getxattr(fd, "user.backup_setup_test") != b"ok":
        raise RuntimeError("Extended attribute verification failed")
finally:
    os.close(fd)
    os.unlink(path)
PY

install -d -o root -g root -m 0755 /etc/ssh/backup-keys /etc/ssh/sshd_config.d
printf 'restrict %s %s\n' "$key_type" "$key_blob" > "$work_dir/authorized_keys"
# The key is public. Read permission lets sshd open it as the unprivileged user;
# root ownership prevents that user from authorizing additional keys.
if [[ -e $key_file ]]; then
  cp -p -- "$key_file" "$work_dir/previous.key"
  had_key=1
fi
key_written=1
install -o root -g root -m 0644 "$work_dir/authorized_keys" "$key_file"

cat > "$work_dir/receiver.conf" <<EOF
# Managed by setup-debian-backup-server.sh; applies only to $account.
Match User $account
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthorizedKeysFile $key_file
    AuthorizedKeysCommand none
    TrustedUserCAKeys none
    DisableForwarding yes
    PermitTunnel no
    PermitTTY no
    PermitUserRC no
    ForceCommand /usr/bin/rrsync -wo -no-del $data_dir
Match all
EOF
if [[ -e $conf_file ]]; then
  cp -p -- "$conf_file" "$work_dir/previous.conf"
  had_conf=1
fi
conf_written=1
install -o root -g root -m 0644 "$work_dir/receiver.conf" "$conf_file"
/usr/sbin/sshd -t
/usr/sbin/sshd -T -C "user=$account,host=localhost,addr=127.0.0.1" > "$work_dir/effective.conf"
for expected in \
  'pubkeyauthentication yes' \
  'authenticationmethods publickey' \
  'passwordauthentication no' \
  'kbdinteractiveauthentication no' \
  "authorizedkeysfile $key_file" \
  'authorizedkeyscommand none' \
  'trustedusercakeys none' \
  'disableforwarding yes' \
  'permittunnel no' \
  'permittty no' \
  'permituserrc no' \
  "forcecommand /usr/bin/rrsync -wo -no-del $data_dir"; do
  grep -Fxq -- "$expected" "$work_dir/effective.conf" ||
    die "An existing SSH rule overrides the required setting: $expected"
done

systemctl enable ssh
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
else
  systemctl start ssh
fi
committed=1

cat <<EOF

Backup receiver configured.
Account: $account
Storage: $data_dir
Public-key fingerprint:
EOF
ssh-keygen -l -f "$work_dir/source.pub"
printf '\nSSH host-key fingerprints (compare when connecting from the source):\n'
for host_key in /etc/ssh/ssh_host_*_key.pub; do
  [[ -f $host_key ]] && ssh-keygen -l -f "$host_key"
done

cat <<EOF

Run this Bash snippet AS ROOT ON THE SOURCE machine.
Install rsync there, replace BACKUP_SERVER, and keep the private key there.
Verify the server host-key fingerprint on the first connection.
If SSH uses a custom port, add -p PORT inside the ssh command below.
Do not use ssh mkdir/chmod: this account accepts rsync uploads only.

remote='$account@BACKUP_SERVER'
key='/root/.ssh/backup_ed25519'
name="\$(hostname -s | tr -c 'A-Za-z0-9_.-' '_')"
dest="\$name-\$(date -u +%Y%m%dT%H%M%S)-\$(od -An -N4 -tx1 /dev/urandom | tr -d ' \\n')"
paths=()
for p in /var/www /etc /home /opt /root /usr/bin /bin /sbin /usr/sbin; do
  [[ -e "\$p" || -L "\$p" ]] || continue
  paths+=("\$p")
done
rsync -aHAXR --numeric-ids -M--fake-super --info=progress2 \\
  -e "ssh -i \$key -o IdentitiesOnly=yes" \\
  -- "\${paths[@]}" "\$remote:\$dest/"

Each upload is stored at $data_dir/NAME-TIMESTAMP-RANDOM/.
A nonzero rsync exit status means the backup needs inspection; failed uploads
remain in place. No snapshots are pruned automatically.

Restore using your normal admin access ON THE BACKUP SERVER. Select an actual
snapshot and use an empty staging directory, not the running machine's /:
  sudo mkdir -p /mnt/restore
  sudo rsync -aHAX --numeric-ids --fake-super -M--super -- \\
    $data_dir/ACTUAL_SNAPSHOT/ /mnt/restore/

The upload key cannot download backups. Restore/download through your admin
account. If SSH uses AllowUsers or AllowGroups, explicitly allow $account there.
EOF
