#!/bin/sh
set -eu

repository=${AVENBAY_RELEASE_REPOSITORY:-hauld/avenbay}
release=${AVENBAY_VERSION:-latest}
install_dir=${AVENBAY_INSTALL_DIR:-/usr/local/bin}
config_dir=/etc/fleet
platform=$(uname -s)

say() {
  printf '%s\n' "[avenbay] $*"
}

fail() {
  printf '%s\n' "[avenbay] error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this installer as root (curl ... | sudo sh)"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$platform" in
  Linux)
    release_os=linux
    root_group=root
    worker_user=fleet
    state_dir=/var/lib/fleet
    project_root=/home/fleet/projects
    service_path=/etc/systemd/system/fleet-worker.service
    command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
    ;;
  Darwin)
    release_os=darwin
    root_group=wheel
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    export PATH
    worker_user=${AVENBAY_RUN_USER:-${SUDO_USER:-}}
    if [ -z "$worker_user" ] || [ "$worker_user" = root ]; then
      worker_user=$(stat -f '%Su' /dev/console)
    fi
    [ -n "$worker_user" ] && [ "$worker_user" != root ] && id "$worker_user" >/dev/null 2>&1 || \
      fail "cannot determine the macOS login user; set AVENBAY_RUN_USER"
    worker_home=$(dscl . -read "/Users/${worker_user}" NFSHomeDirectory | sed 's/^[^:]*: //')
    [ -n "$worker_home" ] || fail "cannot determine the home directory for ${worker_user}"
    worker_group=$(id -gn "$worker_user")
    state_dir=/Users/Shared/fleet
    project_root=${state_dir}/projects
    service_path=/Library/LaunchDaemons/com.avenbay.worker.plist
    command -v launchctl >/dev/null 2>&1 || fail "launchd is required"
    command -v shasum >/dev/null 2>&1 || fail "shasum is required"
    ;;
  *) fail "unsupported operating system: ${platform}" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) architecture=amd64 ;;
  aarch64|arm64) architecture=arm64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

if ! command -v tmux >/dev/null 2>&1; then
  say "installing tmux"
  if [ "$platform" = Darwin ]; then
    if command -v brew >/dev/null 2>&1; then
      sudo -H -u "$worker_user" "$(command -v brew)" install tmux </dev/null
    else
      fail "tmux is required; install Homebrew and run 'brew install tmux' first"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
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

asset="avenbay_${release_os}_${architecture}.tar.gz"
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
if [ "$platform" = Darwin ]; then
  actual_checksum=$(shasum -a 256 "${temporary_dir}/${asset}" | awk '{ print $1 }')
else
  actual_checksum=$(sha256sum "${temporary_dir}/${asset}" | awk '{ print $1 }')
fi
[ "$actual_checksum" = "$expected_checksum" ] || fail "worker archive checksum mismatch"

tar -xzf "${temporary_dir}/${asset}" -C "$temporary_dir"
[ -f "${temporary_dir}/avenbay" ] || fail "worker archive is invalid"
[ -f "${temporary_dir}/fleet-session" ] || fail "session CLI is missing from worker archive"

if [ "$platform" = Linux ]; then
  [ -f "${temporary_dir}/fleet-worker.service" ] || fail "worker service is missing"
  if ! id "$worker_user" >/dev/null 2>&1; then
    say "creating the ${worker_user} service account"
    useradd --system --create-home --shell /bin/bash "$worker_user"
  fi
  worker_group=$(id -gn "$worker_user")
else
  case "${worker_user}${worker_group}${worker_home}" in
    *'&'*|*'<'*|*'>'*|*'"'*) fail "macOS account paths contain unsupported XML characters" ;;
  esac
  cat > "${temporary_dir}/com.avenbay.worker.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.avenbay.worker</string>
  <key>ProgramArguments</key>
  <array><string>${install_dir}/avenbay</string><string>serve</string></array>
  <key>UserName</key><string>${worker_user}</string>
  <key>GroupName</key><string>${worker_group}</string>
  <key>WorkingDirectory</key><string>${project_root}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${worker_home}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>/Users/Shared/fleet/worker.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/fleet/worker-error.log</string>
</dict>
</plist>
EOF
  printf '%s\n' "$worker_group" > "${temporary_dir}/service-group"
fi

if [ "$platform" = Darwin ] && [ -d /Users/Shared/Avenbay ] && [ ! -e "$state_dir" ]; then
  say "migrating /Users/Shared/Avenbay to ${state_dir}"
  mv /Users/Shared/Avenbay "$state_dir"
fi

install -d -o root -g "$root_group" -m 0755 "$install_dir"
install -d -o root -g "$worker_group" -m 0750 "$config_dir"
install -d -o "$worker_user" -g "$worker_group" -m 0700 "$state_dir"
install -d -o "$worker_user" -g "$worker_group" -m 0750 "$project_root"
install -o root -g "$root_group" -m 0755 "${temporary_dir}/avenbay" "${install_dir}/avenbay"
install -o root -g "$root_group" -m 0755 "${temporary_dir}/fleet-session" "${install_dir}/fleet-session"
if [ "$platform" = Linux ]; then
  install -o root -g "$root_group" -m 0644 "${temporary_dir}/fleet-worker.service" "$service_path"
else
  install -o root -g wheel -m 0644 "${temporary_dir}/com.avenbay.worker.plist" "$service_path"
  install -o root -g wheel -m 0644 "${temporary_dir}/service-group" "${config_dir}/service-group"
fi
if [ ! -e "${install_dir}/fleet-worker" ]; then
  ln -s avenbay "${install_dir}/fleet-worker"
fi

if [ ! -e "${config_dir}/worker.env" ]; then
  install -o root -g "$worker_group" -m 0640 /dev/null "${config_dir}/worker.env"
fi

if [ "$platform" = Darwin ] && grep -q '/Users/Shared/Avenbay' "${config_dir}/worker.env"; then
  sed -i '' 's#/Users/Shared/Avenbay#/Users/Shared/fleet#g' "${config_dir}/worker.env"
fi

if [ "$platform" = Linux ]; then
  systemctl daemon-reload
elif grep -q '^FLEET_WORKER_TOKEN=.' "${config_dir}/worker.env"; then
  launchctl bootout system/com.avenbay.worker >/dev/null 2>&1 || true
  launchctl bootstrap system "$service_path"
  launchctl enable system/com.avenbay.worker
  launchctl kickstart -k system/com.avenbay.worker
fi
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" "${install_dir}/avenbay" doctor

say "Avenbay worker installed successfully"
printf '%s\n' \
  "" \
  "Next:" \
  "  1. In Avenbay, open Hosts -> Add host." \
  "  2. Change to the directory containing your projects." \
  "  3. Run the generated sudo avenbay enroll command." \
  "  4. The command uses that directory as its project root and starts the worker." \
  "" \
  "Worker account: ${worker_user}" \
  "Prepared project directory: ${project_root}"
