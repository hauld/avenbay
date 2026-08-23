#!/bin/sh
set -eu

repository=${AVENBAY_RELEASE_REPOSITORY:-hauld/avenbay}
release=${AVENBAY_VERSION:-latest}
install_dir=${AVENBAY_INSTALL_DIR:-/usr/local/bin}
worker_user=fleet
config_dir=/etc/fleet
state_dir=/var/lib/fleet
service_path=/etc/systemd/system/fleet-worker.service

say() {
  printf '%s\n' "[avenbay] $*"
}

fail() {
  printf '%s\n' "[avenbay] error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this installer as root (curl ... | sudo sh)"
[ "$(uname -s)" = Linux ] || fail "fleet-worker currently supports Linux hosts"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

case "$(uname -m)" in
  x86_64|amd64) architecture=amd64 ;;
  aarch64|arm64) architecture=arm64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

if ! command -v tmux >/dev/null 2>&1; then
  say "installing tmux"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update </dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y tmux ca-certificates </dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y tmux ca-certificates </dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y tmux ca-certificates </dev/null
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install tmux ca-certificates </dev/null
  else
    fail "tmux is missing and no supported package manager was found"
  fi
fi

asset="avenbay_linux_${architecture}.tar.gz"
if [ "$release" = latest ]; then
  download_base="https://github.com/${repository}/releases/latest/download"
else
  download_base="https://github.com/${repository}/releases/download/${release}"
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

say "downloading ${asset} (${release})"
curl --fail --silent --show-error --location \
  "${download_base}/${asset}" -o "${temporary_dir}/${asset}"
curl --fail --silent --show-error --location \
  "${download_base}/checksums.txt" -o "${temporary_dir}/checksums.txt"

expected_checksum=$(awk -v asset="$asset" '$2 == asset { print $1 }' "${temporary_dir}/checksums.txt")
[ -n "$expected_checksum" ] || fail "release checksum for ${asset} was not found"
actual_checksum=$(sha256sum "${temporary_dir}/${asset}" | awk '{ print $1 }')
[ "$actual_checksum" = "$expected_checksum" ] || fail "worker archive checksum mismatch"

tar -xzf "${temporary_dir}/${asset}" -C "$temporary_dir"
[ -f "${temporary_dir}/avenbay" ] || fail "worker archive is invalid"
[ -f "${temporary_dir}/fleet-worker.service" ] || fail "worker service is missing"

if ! id "$worker_user" >/dev/null 2>&1; then
  say "creating the ${worker_user} service account"
  useradd --system --create-home --shell /bin/bash "$worker_user"
fi

worker_group=$(id -gn "$worker_user")
install -d -o root -g root -m 0755 "$install_dir"
install -d -o root -g "$worker_group" -m 0750 "$config_dir"
install -d -o "$worker_user" -g "$worker_group" -m 0700 "$state_dir"
install -d -o "$worker_user" -g "$worker_group" -m 0750 "/home/${worker_user}/projects"
install -o root -g root -m 0755 "${temporary_dir}/avenbay" "${install_dir}/avenbay"
install -o root -g root -m 0644 "${temporary_dir}/fleet-worker.service" "$service_path"
if [ ! -e "${install_dir}/fleet-worker" ]; then
  ln -s avenbay "${install_dir}/fleet-worker"
fi

if [ ! -e "${config_dir}/worker.env" ]; then
  install -o root -g "$worker_group" -m 0640 /dev/null "${config_dir}/worker.env"
fi

systemctl daemon-reload
"${install_dir}/avenbay" doctor

say "fleet-worker installed successfully"
printf '%s\n' \
  "" \
  "Next:" \
  "  1. In Avenbay, open Hosts -> Add host." \
  "  2. Run the single-use enrollment command." \
  "  3. Save its values in ${config_dir}/worker.env." \
  "  4. Set FLEET_ALLOWED_ROOTS and FLEET_ALLOWED_EXECUTABLES." \
  "  5. Start the worker:" \
  "" \
  "     sudo systemctl enable --now fleet-worker"
