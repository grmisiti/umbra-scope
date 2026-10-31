#!/bin/zsh
# Copies build/UmbraLink.ofx.bundle into /Library/OFX/Plugins (asks for your password). Restart Resolve afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/UmbraLink.ofx.bundle ]] || Plugin/build_plugin.sh
sudo rm -rf /Library/OFX/Plugins/UmbraLink.ofx.bundle
sudo ditto build/UmbraLink.ofx.bundle /Library/OFX/Plugins/UmbraLink.ofx.bundle
# Owned by root and not writable by others: code that Resolve loads must not be replaceable without the password.
sudo chown -R root:wheel /Library/OFX/Plugins/UmbraLink.ofx.bundle
sudo chmod -R go-w /Library/OFX/Plugins/UmbraLink.ofx.bundle
echo "installed /Library/OFX/Plugins/UmbraLink.ofx.bundle — restart DaVinci Resolve"
