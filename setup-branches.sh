#!/bin/bash
# Builds the branch structure: master = pristine upstream n6.1.3, anon/plex = Plex's delta on top.
set -euo pipefail
cd "$(dirname "$0")/ffmpeg"

git switch -C master >/dev/null 2>&1
git switch -C anon/plex >/dev/null 2>&1

# Swap the worktree for Plex's tree so the commit diff *is* their delta.
find . -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
cp -a ../plex-src/. .

git add -A
git commit -q -m "plex transcoder modifications (ffmpeg-gpl-c75335c5e1ba)"
git --no-pager diff --stat master anon/plex | tail -1
