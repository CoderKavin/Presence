# GalaxyFont

**Change the system UI font on a Samsung Galaxy S24 FE** — to Product Sans, SF Pro,
or any TTF — using the method that actually works for *your* One UI version.

There is no single magic APK that changes the font on every Galaxy. Samsung's
font lockdown has tightened with each One UI release, so GalaxyFont's job is to
(1) tell you which method works on your firmware and (2) build the FlipFont
package for you from any font file.

> 🔗 **Web app:** open `index.html` (or deploy the repo — it's a static site).
> Pick a font → pick your One UI version → follow the generated install plan.

---

## TL;DR — does it work on my phone?

| One UI version | Non-root? | Method that works | Notes |
|---|---|---|---|
| **One UI 5 / older** | ✅ Yes | Self-signed **FlipFont APK** (this repo) | Build, sign, install, select. |
| **One UI 6 / 6.1** (S24 FE launch) | ✅ Yes | **zFont 3** / **#mono_** companion, or **ADB** | Signature gate rejects plain self-signed APKs. |
| **One UI 7** | ✅ Yes | **zFont 3** / **#mono_** companion, or **ADB** | Same gate; companion apps hold valid credentials. |
| **One UI 8** | ⚠️ Mostly | **#mono_ v2.1** (reported working to ~8.0), ADB | Increasingly locked. |
| **One UI 8.5+** | ❌ No | **Root (Magisk)** only | `fs-verity` blocks all non-root font application. |

The S24 FE shipped on **One UI 6.1** and updates into the 7/8 range, so in
practice you'll most often use the **companion-app or ADB** route.

Everything here is **reversible** (Settings → Display → Font size and style →
*Default*) and **non-destructive** — nothing is flashed, no system partition is
touched.

---

## Why isn't Product Sans / SF Pro just included?

Both are **proprietary** and not licensed for redistribution, so shipping the
TTFs would be copyright infringement. GalaxyFont builds the *package mechanism*
and packs in the font file **you** supply.

Free, ship-able alternatives:

- **SF Pro →** [Inter](https://rsms.me/inter/) (SIL OFL) — extremely close, included in the preview.
- **Product Sans →** [Nunito Sans](https://fonts.google.com/specimen/Nunito+Sans) (OFL) — a reasonable stand-in.

If you own the real fonts (e.g. SF Pro from Apple's developer site, or a
Product Sans TTF you're licensed for), drop them into the builder.

---

## How a Samsung font package works (FlipFont)

One UI enumerates installed apps whose package id starts with
`com.monotype.android.font.*` and that contain:

```
com.monotype.android.font.<name>/
├── AndroidManifest.xml          # package id + font name meta-data
├── assets/
│   ├── fonts/<Name>.ttf         # the actual font
│   └── xml/<Name>.xml           # FlipFont descriptor: family → ttf
└── res/values/strings.xml
```

The descriptor (`assets/xml/<Name>.xml`) maps a family name to the bundled TTFs.
The `<fileset>` is **positional** — Regular, Bold, Italic, Bold-Italic:

```xml
<familyset>
  <family>
    <nameset><name>SFPro</name><name>sans-serif</name></nameset>
    <fileset>
      <file>SFPro-Regular.ttf</file>
      <file>SFPro-Bold.ttf</file>
      <file>SFPro-Italic.ttf</file>
      <file>SFPro-BoldItalic.ttf</file>
    </fileset>
  </family>
</familyset>
```

Once installed (and accepted by the firmware), the font appears under
**Settings → Display → Font size and style**.

### Weights (Bold / Italic / Semibold)

Supply one TTF per weight. Real **Bold** and **Italic** are used where you
provide them; any missing slot falls back to Regular (so bold becomes
faux-bold). **One UI does not expose Medium/Semibold as separately selectable
system weights** — apps that request bold get the Bold file, and Regular covers
everything else. So "Regular + Bold (+ italics)" is the practical maximum the
system font picker uses.

### Switching between fonts (e.g. SF Pro ⇄ Google Sans)

Build and install a package for **each** font. Every installed font shows up in
**Settings → Display → Font size and style** at once — tap to switch between
them, or pick **Default** to revert. The switching is done in One UI's own font
picker; GalaxyFont just gets each font into that list.

---

## Build a FlipFont APK from the command line

The web app produces this same package as a downloadable zip; the CLI does it
end-to-end including signing.

```bash
# Requires Android SDK build-tools (aapt2, zipalign, apksigner) + a JDK on PATH
export ANDROID_JAR=$ANDROID_HOME/platforms/android-34/android.jar

# <FontName> <regular.ttf> [bold.ttf] [italic.ttf] [bolditalic.ttf]
tools/make-flipfont.sh SFPro ~/fonts/SFPro-Regular.ttf ~/fonts/SFPro-Bold.ttf
# → build-SFPro/SFPro-signed.apk

adb install build-SFPro/SFPro-signed.apk
# Apply on phone: Settings → Display → Font size and style → SFPro
```

Only the Regular weight is required; add Bold/Italic/Bold-Italic in that order.
`FontName` must be a single token (letters/digits, no spaces) — a FlipFont
requirement.

---

## If the APK is rejected ("fonts not compatible")

That's the **signature gate** on One UI 6.1+. Use one of these instead — they
take the *same* TTF:

### Option A — zFont 3 (easiest)
1. Install **zFont 3** from the Play Store.
2. Import your TTF → choose **Galaxy / One UI** mode → **Apply**.
3. Reboot if prompted. Select the font in Settings if needed.

### Option B — #mono_ (no-root sideloader, works to ~One UI 8)
1. Copy your TTF to `/sdcard/monofonts/ttf/` (create the folder if missing).
2. Open **#mono_**, pick the font, apply.

### Option C — ADB (no extra app for selection)
```bash
adb push SFPro.ttf /sdcard/Download/SFPro.ttf
# select an already-registered font by its index:
adb shell settings put global font_style_index <index>
# revert:
adb shell settings put global font_style_index 0
```

### Option D — One UI 8.5+ (root)
Non-root is fully blocked by `fs-verity`. Root with Magisk (note: unlocking the
bootloader trips Knox permanently) and apply the font via a systemless font
module or a root-satisfied FlipFont install.

---

## Revert to the stock font

**Settings → Display → Font size and style → Default**, or:

```bash
adb shell settings put global font_style_index 0
```

---

## Repo layout

```
index.html             # the GalaxyFont web app (static, deployable)
tools/make-flipfont.sh # CLI: TTF → signed FlipFont APK
README.md              # this file
```

---

## Disclaimer

Not affiliated with Samsung, Monotype, Apple, or Google. *Product Sans* and
*SF Pro* are trademarks of their respective owners and are **not** distributed
here. Use only fonts you are licensed to use. Modifying device fonts is at your
own risk; everything documented here is reversible and non-root except where
explicitly noted.

### Method sources (XDA community research)
- [One UI 8.5 font-bypass research — every non-root approach tested](https://xdaforums.com/t/oneui-8-5-font-bypass-research-every-non-root-approach-tested.4782338/)
- [#mono_ FlipFont + custom TTF installer (no-root)](https://xdaforums.com/t/app-mono_-flipfont-custom-ttf-installer-v2-1-for-samsung-oneui-1-2-3-no-root.4195613/)
- [FlipFonts for Samsung Galaxy phones (all working)](https://xdaforums.com/t/flipfonts-for-samsung-galaxy-phones-all-working.4444893/)
