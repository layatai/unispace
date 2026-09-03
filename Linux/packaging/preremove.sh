#!/bin/sh
set -eu
systemctl --global disable unispace.service >/dev/null 2>&1 || true
