#!/bin/bash
set -e
DEST="Sources/MDViewerCore/Resources/katex"
mkdir -p "$DEST/fonts"

VERSION="0.16.21"
BASE="https://cdn.jsdelivr.net/npm/katex@${VERSION}/dist"

curl -L -o "$DEST/katex.min.js" "${BASE}/katex.min.js"
curl -L -o "$DEST/katex.min.css" "${BASE}/katex.min.css"

for font in KaTeX_Main-Regular KaTeX_Main-Bold KaTeX_Main-Italic KaTeX_Main-BoldItalic \
            KaTeX_Math-Italic KaTeX_Math-BoldItalic \
            KaTeX_Size1-Regular KaTeX_Size2-Regular KaTeX_Size3-Regular KaTeX_Size4-Regular \
            KaTeX_AMS-Regular KaTeX_Caligraphic-Regular KaTeX_Caligraphic-Bold \
            KaTeX_Fraktur-Regular KaTeX_Fraktur-Bold \
            KaTeX_SansSerif-Regular KaTeX_SansSerif-Bold KaTeX_SansSerif-Italic \
            KaTeX_Script-Regular KaTeX_Typewriter-Regular; do
    curl -sL -o "$DEST/fonts/${font}.woff2" "${BASE}/fonts/${font}.woff2"
done

echo "KaTeX ${VERSION} downloaded to ${DEST}"
ls -la "$DEST/katex.min.js" "$DEST/katex.min.css"
echo "Fonts: $(ls "$DEST/fonts/" | wc -l | tr -d ' ') files"
