#!/usr/bin/env bash
set -euo pipefail

echo "==> bundle install"
bundle install

# --force_polling is required, not optional: Colima mounts the project over
# virtiofs with mountInotify=false, so host file edits raise no inotify events
# inside the container and --watch alone would never rebuild.
echo "==> jekyll serve -> http://localhost:4000"
exec bundle exec jekyll serve \
  --host 0.0.0.0 \
  --port 4000 \
  --force_polling \
  --livereload
