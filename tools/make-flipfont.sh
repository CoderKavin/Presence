#!/usr/bin/env bash
#
# make-flipfont.sh — turn TTF weight files into a signed Samsung FlipFont APK.
#
# This is the command-line equivalent of the GalaxyFont web app's
# "Download FlipFont package" + "build.sh" steps, in one shot.
#
# Usage:
#   ./make-flipfont.sh <FontName> <regular.ttf> [bold.ttf] [italic.ttf] [bolditalic.ttf]
#
# Weight order is positional (Regular, Bold, Italic, Bold-Italic) — the same
# order One UI's FlipFont fileset expects. Only Regular is required.
#
# Requirements (all from the Android SDK + a JDK, must be on PATH):
#   aapt2  zipalign  apksigner  keytool
# And:
#   export ANDROID_JAR=$ANDROID_HOME/platforms/android-34/android.jar
#
# Heads-up: One UI 6.1+ verifies the signing certificate and rejects
# self-signed FlipFont APKs. On those builds, import the TTFs through
# zFont 3 / #mono_ instead, or root the device. See ../README.md.

set -euo pipefail

NAME="${1:-}"
shift || true
SUFFIXES=(Regular Bold Italic BoldItalic)

if [[ -z "$NAME" || -z "${1:-}" ]]; then
  echo "Usage: $0 <FontName> <regular.ttf> [bold.ttf] [italic.ttf] [bolditalic.ttf]" >&2
  exit 1
fi
# FlipFont family names must be a single token (no spaces/symbols).
if [[ ! "$NAME" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ERROR: FontName must be one word, letters/digits only (e.g. SFPro)." >&2
  exit 1
fi

: "${ANDROID_JAR:?set ANDROID_JAR to your platforms/android-XX/android.jar}"
for t in aapt2 zipalign apksigner keytool; do
  command -v "$t" >/dev/null || { echo "ERROR: '$t' not on PATH (install Android SDK build-tools / JDK)." >&2; exit 1; }
done

PKG="com.monotype.android.font.$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
OUT="$(pwd)/build-$NAME"
rm -rf "$OUT"; mkdir -p "$OUT/assets/fonts" "$OUT/assets/xml" "$OUT/res/values"

# copy each provided weight into its positional slot, building the fileset
FILESET=""
i=0
for ttf in "$@"; do
  [[ $i -ge ${#SUFFIXES[@]} ]] && { echo "WARN: ignoring extra file '$ttf' (max 4 weights)." >&2; break; }
  if [[ ! -f "$ttf" ]]; then echo "ERROR: font file not found: $ttf" >&2; exit 1; fi
  dest="$NAME-${SUFFIXES[$i]}.ttf"
  cp "$ttf" "$OUT/assets/fonts/$dest"
  FILESET="$FILESET            <file>$dest</file>"$'\n'
  i=$((i+1))
done

cat > "$OUT/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$PKG" android:versionCode="1" android:versionName="1.0">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
    <application android:label="$NAME" android:hasCode="false">
        <meta-data android:name="com.monotype.android.font.name" android:value="$NAME" />
    </application>
</manifest>
EOF

# positional fileset: Regular, Bold, Italic, Bold-Italic
cat > "$OUT/assets/xml/$NAME.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<familyset>
    <family>
        <nameset>
            <name>$NAME</name>
            <name>sans-serif</name>
        </nameset>
        <fileset>
${FILESET}        </fileset>
    </family>
</familyset>
EOF

cat > "$OUT/res/values/strings.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">$NAME</string></resources>
EOF

cd "$OUT"

if [[ ! -f flipfont.keystore ]]; then
  keytool -genkeypair -keystore flipfont.keystore -storepass android \
    -keypass android -alias flipfont -keyalg RSA -keysize 2048 \
    -validity 10000 -dname "CN=GalaxyFont"
fi

aapt2 compile --dir res -o res.zip
aapt2 link -o "$NAME-unsigned.apk" -I "$ANDROID_JAR" \
  --manifest AndroidManifest.xml -R res.zip --auto-add-overlay -A assets
zipalign -f 4 "$NAME-unsigned.apk" "$NAME-aligned.apk"
apksigner sign --ks flipfont.keystore --ks-pass pass:android \
  --out "$NAME-signed.apk" "$NAME-aligned.apk"

echo
echo "✓ Built $OUT/$NAME-signed.apk"
echo "  Install:  adb install \"$OUT/$NAME-signed.apk\""
echo "  Apply:    Settings → Display → Font size and style → $NAME"
