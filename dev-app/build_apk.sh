#!/usr/bin/env bash
# Baut das PDF-Studio-Release-APK und legt es ab:
#   ../downloads/pdf-studio-<version>+<build>.apk  und  ../version.xml (zuletzt!)
# Aufruf: ./build_apk.sh "Änderungshinweis"
# Version/Build kommen aus pubspec.yaml (vorher hochzählen).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="$(cd "$ROOT/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/development/flutter/bin:$PATH"

NOTES="${1:-}"
KEEP=0   # 0 = alte APKs nie löschen (Sicherheit)

VERSION_LINE="$(grep -E '^version:' pubspec.yaml | head -n1)"
if [[ ! "$VERSION_LINE" =~ version:[[:space:]]*([0-9.]+)\+([0-9]+) ]]; then
    echo "Version in pubspec.yaml nicht lesbar: $VERSION_LINE" >&2
    exit 1
fi
VERSION="${BASH_REMATCH[1]}"
BUILD="${BASH_REMATCH[2]}"

if [[ ! -f "$HOME/keys/pdf-studio-key.properties" ]]; then
    echo "Release-Schlüssel fehlt (~/keys/pdf-studio-key.properties) – Abbruch." >&2
    exit 1
fi

if [[ -f "$SITE/version.xml" ]]; then
    OLD_BUILD="$(sed -n 's:.*<build>\([0-9]*\)</build>.*:\1:p' "$SITE/version.xml")"
    if [[ -n "$OLD_BUILD" && "$BUILD" -le "$OLD_BUILD" ]]; then
        echo "Build $BUILD ist nicht größer als veröffentlichter Build $OLD_BUILD – pubspec.yaml hochzählen." >&2
        exit 1
    fi
fi
if [[ -z "$NOTES" ]]; then
    echo "Bitte Änderungshinweis angeben: $0 \"Neu: …\"" >&2
    exit 1
fi

echo "Baue PDF-Studio $VERSION (Build $BUILD) …"
# x86_64 nur für Emulatoren – spart ~25 MB
flutter build apk --release --target-platform android-arm,android-arm64

NAME="pdf-studio-${VERSION}+${BUILD}.apk"
mkdir -p "$SITE/downloads"
cp -f build/app/outputs/flutter-apk/app-release.apk "$SITE/downloads/$NAME"
SHA="$(sha256sum "$SITE/downloads/$NAME" | cut -d' ' -f1)"

# Alte APKs nur löschen, wenn KEEP > 0
if (( KEEP > 0 )); then
    ls -1t "$SITE"/downloads/pdf-studio-*.apk | tail -n +$((KEEP + 1)) | xargs -r rm -f
fi

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

# version.xml zuletzt schreiben (atomar), damit nie auf ein fehlendes APK verwiesen wird
TMP="$(mktemp "$SITE/.version.xml.XXXXXX")"
cat >"$TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<pdfstudio>
    <version>${VERSION}</version>
    <build>${BUILD}</build>
    <label>${VERSION} (Build ${BUILD})</label>
    <apk_url>downloads/${NAME}</apk_url>
    <sha256>${SHA}</sha256>
    <notes>$(esc "$NOTES")</notes>
</pdfstudio>
EOF
chmod 644 "$TMP"
mv -f "$TMP" "$SITE/version.xml"

echo "OK: downloads/$NAME"
echo "    sha256 $SHA"
echo "Lokal fertig. Hochladen auf den Server: erst das APK, zuletzt version.xml (nur mit OK)."
