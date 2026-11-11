#!/usr/bin/env bash
# install.sh: make "os-buddy" a command you can run from anywhere.
# It links bin/os-buddy into ~/.local/bin (no sudo needed) and
# creates the config folder. Run again any time; it is safe to repeat.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
bin_dir="$HOME/.local/bin"
config_dir="$HOME/.config/os-buddy"

mkdir -p "$bin_dir" "$config_dir"
chmod +x "$here/bin/os-buddy"
ln -sf "$here/bin/os-buddy" "$bin_dir/os-buddy"     # a link, so edits apply at once
echo "linked $bin_dir/os-buddy -> $here/bin/os-buddy"

# Copy the example config only if there is no config yet.
if [[ ! -e "$config_dir/config" ]]; then
  cp "$here/examples/config.example" "$config_dir/config"
  chmod 600 "$config_dir/config"                   # it will hold your API key
  echo "created $config_dir/config (add your GEMINI_API_KEY there)"
fi

# Warn if ~/.local/bin is not on PATH.
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "note: add this to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
