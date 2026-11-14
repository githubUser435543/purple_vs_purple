#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <ip> <username> <password>" >&2
    exit 1
fi

ip="$1"
username="$2"
password="$3"

outdir="$HOME/flags"
outfile="$outdir/${ip}_${username}_flag"

umask 077
mkdir -p "$outdir"

tmp=$(mktemp "$outdir/.flag.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if SSHPASS="$password" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    "$username@$ip" 'cat "$HOME/flag.txt"' > "$tmp"; then

    mv -f "$tmp" "$outfile"
    echo "Flag saved: $outfile"
else
    echo "Failed to retrieve flag from $ip" >&2
    exit 1
fi
