#!/bin/sh
# Renders the static images that come from HTML sources in this folder, using the
# host's headless Chrome (macOS path; override with CHROME=...). Run from anywhere:
#   script/render-images.sh
set -eu
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
shot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
           --window-size="$2" --screenshot="$3" "file://$PWD/$1" 2>/dev/null; }

shot script/og-card.html 1200,630 assets/img/og.png

# Headless Chrome on macOS won't make a window this small, so shoot big with the icon centered, then center-crop.
shot script/touch-icon.html 500,500 assets/img/apple-touch-icon.png
sips -c 180 180 assets/img/apple-touch-icon.png >/dev/null

echo "wrote assets/img/og.png and assets/img/apple-touch-icon.png"
