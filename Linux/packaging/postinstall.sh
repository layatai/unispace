#!/bin/sh
set -eu
if ! getent group unispace >/dev/null 2>&1; then
    groupadd --system unispace
fi
modprobe uinput || true
udevadm control --reload-rules || true
udevadm trigger --name-match=uinput || true
systemctl --global enable unispace.service >/dev/null 2>&1 || true
printf '%s\n' 'UniSpace installed. Add each receiver user to the dedicated input group:'
printf '%s\n' '  sudo usermod -aG unispace USERNAME'
printf '%s\n' 'Then sign out and back in before pairing.'
