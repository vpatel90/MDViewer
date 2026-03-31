#!/bin/bash
set -e
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

cd "$WORK"
npm init -y --silent > /dev/null 2>&1
npm install --silent \
  markdown-it-footnote@4 \
  markdown-it-emoji@3 \
  markdown-it-mark@4 \
  markdown-it-sub@2 \
  markdown-it-sup@2 \
  esbuild@latest > /dev/null 2>&1

cat > entry.js << 'ENTRY'
window.markdownitFootnote = require('markdown-it-footnote');
window.markdownitEmoji = require('markdown-it-emoji');
window.markdownitMark = require('markdown-it-mark');
window.markdownitSub = require('markdown-it-sub');
window.markdownitSup = require('markdown-it-sup');
ENTRY

npx esbuild entry.js --bundle --outfile=bundle.js --format=iife --minify --platform=browser 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${1:-$REPO_ROOT/Sources/MDViewerCore/Resources/markdown-it-plugins.min.js}"
cp bundle.js "$DEST"
echo "Bundled to $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes)"
