#!/usr/bin/env bash
set -euo pipefail

remote='root@BACKUP_SERVER'

ssh "$remote" 'install -d -m 700 /srv/backups/pvp'

paths=()
for p in /var/www /etc /home /opt /root /usr/bin /bin /sbin /usr/sbin; do
  [[ -e "$p" || -L "$p" ]] || continue
  paths+=("$p")
done

rsync -aHAXR --numeric-ids --info=progress2 \
  -- "${paths[@]}" "$remote:/srv/backups/pvp/"

ssh "$remote" 'chmod 700 /srv/backups/pvp'
