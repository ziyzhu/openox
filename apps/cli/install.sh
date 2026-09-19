#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

download() {
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 300 "$1" -o "$2"
}

install_ox() {
  for tool in uname ls curl tar gzip mktemp tr sed awk sort head chmod mv rm mkdir; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to install Ox CLI"
  done
  if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    checksum_tool=shasum
  else
    fail 'sha256sum or shasum is required to verify the download'
  fi

  case "$(uname -s)" in
    Darwin) platform=darwin ;;
    Linux)
      if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        fail 'Linux with musl libc is not supported yet; use a glibc distribution'
      fi
      platform=linux
      ;;
    *) fail 'Standalone installs support macOS and Linux' ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) platform="$platform-arm64" ;;
    x86_64|amd64) platform="$platform-x64" ;;
    *) fail "Unsupported CPU architecture: $(uname -m)" ;;
  esac

  install_dir=${OX_INSTALL_DIR:-"$HOME/.local/bin"}
  case "$install_dir" in
    /*) ;;
    *) fail 'OX_INSTALL_DIR must be an absolute path' ;;
  esac
  install_dir=${install_dir%/}
  [ -n "$install_dir" ] || install_dir=/
  existing=$(command -v ox 2>/dev/null || true)
  if [ -n "$existing" ] && [ "$existing" != "$install_dir/ox" ]; then
    fail "ox already resolves to $existing. Remove that installation or set OX_INSTALL_DIR to its directory, then retry."
  fi
  [ ! -L "$install_dir/ox" ] || fail "Refusing to replace the symbolic link at $install_dir/ox. Uninstall the previous copy first."
  [ ! -d "$install_dir/ox" ] || fail "$install_dir/ox is a directory"

  mkdir -p "$install_dir"
  staging=$(mktemp -d "$install_dir/.ox-install.XXXXXXXX")
  trap 'rm -rf "$staging"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  version=${OX_CLI_VERSION:-}
  if [ -z "$version" ]; then
    : > "$staging/versions"
    page=1
    while :; do
      download "https://api.github.com/repos/ziyzhu/openox/releases?per_page=100&page=$page" "$staging/releases.json"
      tr ',' '\n' < "$staging/releases.json" > "$staging/release-fields"
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"ox-cli-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$staging/release-fields" >> "$staging/versions"
      release_count=$(awk '/"tag_name"[[:space:]]*:/ { count++ } END { print count + 0 }' "$staging/release-fields")
      [ "$release_count" -eq 100 ] || break
      page=$((page + 1))
    done
    version=$(sort -t . -k1,1nr -k2,2nr -k3,3nr "$staging/versions" | head -n 1)
    [ -n "$version" ] || fail 'No standalone Ox CLI release is available yet'
  fi
  case "$version" in *[!0-9.]*) fail 'OX_CLI_VERSION must be a version such as 0.1.0' ;; esac
  valid_version=$(printf '%s\n' "$version" | sed -n '/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/p')
  [ -n "$valid_version" ] && [ "$version" = "$valid_version" ] || fail 'OX_CLI_VERSION must be a version such as 0.1.0'

  archive="ox-cli-$platform.tar.gz"
  release="https://github.com/ziyzhu/openox/releases/download/ox-cli-v$version"
  printf 'Installing Ox CLI %s for %s...\n' "$version" "$platform"
  download "$release/$archive" "$staging/$archive"
  download "$release/SHA256SUMS" "$staging/SHA256SUMS"
  checksum=$(awk -v archive="$archive" '$2 == archive { hash = $1; count++ } END { if (count != 1) exit 1; print hash }' "$staging/SHA256SUMS") || fail 'Release checksums are missing or ambiguous'
  [ "${#checksum}" -eq 64 ] || fail 'Invalid release checksum'
  case "$checksum" in *[!0-9a-fA-F]*) fail 'Invalid release checksum' ;; esac
  printf '%s  %s\n' "$checksum" "$archive" > "$staging/selected-checksum"
  if [ "$checksum_tool" = sha256sum ]; then
    (cd "$staging" && sha256sum -c selected-checksum) || fail 'Download checksum verification failed'
  else
    (cd "$staging" && shasum -a 256 -c selected-checksum) || fail 'Download checksum verification failed'
  fi

  tar -xzf "$staging/$archive" -C "$staging" ox
  [ -f "$staging/ox" ] && [ ! -L "$staging/ox" ] || fail 'The release does not contain an Ox executable'
  chmod 755 "$staging/ox"
  installed_version=$(cd "$staging" && ./ox --version) || fail 'The downloaded executable could not run on this machine'
  [ "$installed_version" = "$version" ] || fail "Downloaded version $installed_version does not match $version"
  mv -f "$staging/ox" "$install_dir/ox"
  printf 'Installed %s\n' "$install_dir/ox"
  case ":$PATH:" in
    *":$install_dir:"*) printf 'Run: ox --help\n' ;;
    *)
      printf 'Add %s to your shell PATH, then run ox --help.\n' "$install_dir"
      printf 'For bash or zsh: export PATH="%s:$PATH"\n' "$install_dir"
      printf 'For fish: fish_add_path "%s"\n' "$install_dir"
      ;;
  esac
}

install_ox
