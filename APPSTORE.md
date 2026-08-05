# CrispTuner — App Store submission state

Prepared 2026-08-05 following the account playbook in `~/code/appstore.md`.
Everything an agent can do is done. What remains is listed at the bottom.

## Identity

| Thing | Value |
|---|---|
| App name | **CrispTuner** |
| Bundle ID (iOS **and** macOS) | `com.crispstrobe.CrispTuner` |
| Bundle ID resource | `A45A39QTS2` — registered `UNIVERSAL` on 2026-08-05 |
| Team | `N9XSJ4M3GT` (Christian Ströbele) |
| Version | `2.1.0+3` (from `pubspec.yaml`) |
| App record / `ASC_APP_ID` | ✅ **`6798295311`** (created 2026-08-05, verified by bundle id) |
| iOS `appStoreVersion` | `79c81d1a-3303-427a-88f3-aed40f78e8e6` — 2.1.0, `PREPARE_FOR_SUBMISSION` |
| macOS `appStoreVersion` | `4d1bb892-14a2-47fe-83d2-ee71d27d3c1f` — 2.1.0, `PREPARE_FOR_SUBMISSION` |
| Public site | https://crisptuner.vercel.app (Vercel project `crisptuner`) |
| Mirror | https://crispstrobe.github.io/flutter_tuner/ (Pages, publishes on next push) |

Both platform versions were auto-created at `1.0` and have been PATCHed to
**2.1.0** to match the binary's `CFBundleShortVersionString`. They must stay in
sync or the build cannot be attached to the version.

Both platforms deliberately share one bundle ID so App Store Connect serves them
from a **single app record**. Creating a second record would mean a second
browser-only step.

## Provisioning profiles (created 2026-08-05, both `ACTIVE`)

| Profile | Type | ID | UUID |
|---|---|---|---|
| `CrispTuner AppStore CI` | `IOS_APP_STORE` | `2B5UYMD662` | `c7f0a9f5-a8c8-4150-88c3-8cf3662fdf5c` |
| `CrispTuner MacAppStore` | `MAC_APP_STORE` | `W6U2C88N7S` | `03f71ff3-e62b-42d8-b7cc-82dd781e00c3` |

Both are bound to **both** live Distribution certs (`L9PHHNLY9Y` canonical +
`X48Y45DL9F`), so signing works regardless of which one a `.p12` secret holds.
Account-wide profile health was re-checked after creation: **38 profiles, 0
non-ACTIVE** — nothing was collateral damage.

> ⚠️ Never add or remove a **capability** on this bundle ID. Doing so flips every
> profile for it to `INVALID`, including the ones the CI secrets point at, and
> deleting the capability again does not restore them.

## Repo secrets (set 2026-08-05)

| Secret | Set? |
|---|---|
| `ASC_API_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_TEAM_ID` | ✅ |
| `DIST_CERT_P12_BASE64`, `DIST_CERT_PASSWORD` | ✅ |
| `MAC_SIGNING_P12_BASE64`, `MAC_SIGNING_P12_PASSWORD` | ✅ |
| `ASC_PROFILE_BASE64`, `ASC_PROFILE_MACOS_BASE64` | ✅ |
| `ASC_APP_ID` | ✅ `6798295311` |
| `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` | ✅ repointed at the new `crisptuner` project |

The `.p12` was exported headlessly from `brickwright-build.keychain-db` and
verified to carry the **Apple Distribution** identity (`56D3…C632` =
`L9PHHNLY9Y`) *and* the **3rd Party Mac Developer Installer** identity, which the
macOS `.pkg` needs. Throwaway password: `crisptuner-dist`.

## What was fixed for submission

- **App icon had an alpha channel** — Apple rejects that outright in the 1024px
  marketing icon (ITMS-90717). The source was also 642×643, i.e. below 1024 and
  not square. Rebuilt as a squared, opaque RGB 1024px master, plus a separate
  macOS master (squircle on a transparent margin — macOS does *not* mask icons,
  so a full-bleed square would ship with hard corners).
- **Stale `CODE_SIGN_IDENTITY[sdk=iphoneos*] = "iPhone Developer"`** at project
  level (3 occurrences) — conflicts with Automatic signing and mis-signs
  Flutter's embedded frameworks during archive. Removed.
- **`PrivacyInfo.xcprivacy`** added for both platforms and wired into each
  Runner target's Resources phase (missing ⇒ ITMS-91053).
- **`ITSAppUsesNonExemptEncryption=false`** baked into both Info.plists, so
  uploads don't park at `MISSING_EXPORT_COMPLIANCE`.
- **macOS had no `NSMicrophoneUsageDescription` at all** — macOS would deny mic
  access, so pitch detection could never have worked there. Also added the
  `LSApplicationCategoryType` the Mac App Store requires (its absence is a hard
  validation rejection).
- **Top-level `CFBundleIconName`** added (guards against ITMS-90713).
- **Placeholder identifiers** replaced: `com.example.flutterTuner` (macOS),
  `com.example.flutterTuner.RunnerTests`, `com.example.flutter_tuner` (Android).
- **`permission_handler`** removed — an unused dependency that shipped native
  permission code for permissions the app never requests.

## Release workflows

| Workflow | Trigger | Result |
|---|---|---|
| `ios-release.yml` | tag `v*` | signed IPA → App Store Connect |
| `macos-release.yml` | tag `macos-v*` | signed `.pkg` → App Store Connect |

Both accept a manual run with `dry_run=true` to build and sign **without**
uploading. **Do that first** — it validates signing end to end and costs nothing.

They follow the account's canonical shape: archive unsigned, sign at export,
manual signing, no `-allowProvisioningUpdates` (which creates a Development cert
and silently revokes a Distribution cert to stay under Apple's 5-cert cap).
macOS deliberately does *not* use `-exportArchive`, because that re-signs from a
default entitlement set and would drop `com.apple.security.app-sandbox` — an
automatic Mac App Store rejection.

Version rules: bump `+BUILD` or Apple rejects a duplicate `CFBundleVersion`. Once
a version is **approved**, the marketing version `x.y.z` must also increase — a
build-only bump is rejected as ITMS-90062.

## ✅ Listing content — done via API (2026-08-05)

Set on **both** the iOS and macOS versions:

| Field | Value |
|---|---|
| Description, keywords, promo text | en-US **and** de-DE, from `fastlane/metadata/` |
| Support / marketing URL | https://crisptuner.vercel.app/ |
| Subtitle | “Chromatic instrument tuner” / “Chromatisches Stimmgerät” |
| Privacy policy URL | https://crisptuner.vercel.app/privacy.html (verified 200) |
| Category | `MUSIC` primary, `UTILITIES` secondary |
| Copyright | `2026 Christian Ströbele` |
| `usesIdfa` | `false` |
| Age rating | every descriptor `NONE`, every boolean `false` |
| Price | Free (`appPriceSchedule`, USA base territory) |
| App Review contact | Christian Ströbele / `cstr+apple@mailbox.org` / `+4917664646627` |

`whatsNew` was deliberately **not** set — it 409s on a first-ever version.

Two notes for next time: `contests` is a *string enum* (`NONE`) in the 2025 age
questionnaire, and `gunsOrOtherWeapons` + `contests` are both required as soon as
you touch the declaration at all. And reading a category back needs
`?include=primaryCategory` — a plain GET returns the relationship without `data`
and looks empty when it is in fact set.

## ⏭ Remaining steps

### 1. App Privacy "nutrition label" — **human, browser only**
Also not exposed in the API at all (`appDataUsages` etc. 404). App Store Connect
→ **App Privacy** → Get Started → **Data Not Collected**. One click: the app
genuinely collects nothing.

### 2. Screenshots
Not generated yet. They can be produced with no physical device via the iOS
Simulator (`xcrun simctl io <udid> screenshot`) — `debugShowCheckedModeBanner`
is already `false`, so simulator (debug-only) builds are screenshot-clean.
Needed: `APP_IPHONE_67` (1290×2796 or 1320×2868) and, for iPad,
`APP_IPAD_PRO_3GEN_129` (2064×2752).

### 3. Upload a build, then attach it
Nothing is uploaded yet, so the store tile has no icon and neither version can be
submitted. Push the repo, then run each release workflow **with `dry_run=true`
first** to validate signing without uploading:

```bash
gh workflow run ios-release.yml   --repo CrispStrobe/flutter_tuner -f dry_run=true
gh workflow run macos-release.yml --repo CrispStrobe/flutter_tuner -f dry_run=true
```

When those are green, tag for a real upload (`v2.1.0` for iOS, `macos-v2.1.0` for
macOS). After the build reaches `VALID` (15–60 min of processing), attach it:

```
PATCH /v1/appStoreVersions/<version id>/relationships/build  {"data":{"type":"builds","id":"<build id>"}}
```

The App Store tile icon is pulled from the **build attached to the version** —
not from TestFlight and not from the repo — so a version with no build shows a
blank tile.

### 4. Age rating (DONE — kept for reference)
Everything `NONE`/`false`, `ageAssurance` must be present in the PATCH, and set
only `ageRatingOverrideV2` (never both V1 and V2). Reached via the **appInfo**
relationship, not the version.

### 5. Submit for review — **human**
A deliberate decision, not a checklist item.

### ⚠️ Known account-level blocker for TestFlight
This account has hit `ENTITY_UNPROCESSABLE.BETA_CONTRACT_MISSING`, which has no
API and appears to break TestFlight distribution **generally, internal included**
— no internal tester has ever reached `INSTALLED` on this account. Do not plan
on "use an internal group meanwhile" as a workaround. Only the Account Holder can
clear it, in the browser.
