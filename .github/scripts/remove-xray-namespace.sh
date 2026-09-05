#!/bin/sh
# Remove the installed Xray namespace so a systemd CI job starts and ends clean.
#
# Shared by the lifecycle and memory jobs: each one used to carry its own copy of
# this teardown, so a path added to the installer had to be remembered twice and
# leaked state between jobs when it was not.
set -u

sudo systemctl stop xray-socks5.service 2>/dev/null || true
sudo rm -rf /etc/xray-socks5 /var/lib/xray-socks5 \
    /usr/local/libexec/xray-socks5 /etc/systemd/system/xray-socks5.service
sudo userdel xray-socks5 2>/dev/null || true
sudo groupdel xray-socks5 2>/dev/null || true
sudo systemctl daemon-reload 2>/dev/null || true
exit 0
