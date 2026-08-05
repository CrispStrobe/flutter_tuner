# `AppStore.entitlements` — why each key is there

Documentation lives here rather than as XML comments inside the entitlements
file itself, because **`codesign` chokes on angle brackets inside an XML
comment**:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 9
```

This file originally carried a comment containing the text
`` `codesign --entitlements <file>` ``. That `<file>` is perfectly legal XML
inside a comment, but AMFI's parser is far simpler than a real XML parser and
reads it as a tag.

The trap is that **`plutil -lint` reports the file as `OK`** — it uses the
generic plist parser, which handles comments correctly. So the file lints clean
and then fails at signing time, several minutes into a CI run.

Verified both ways: a comment with no angle brackets signs fine; the same
comment containing `<file>` fails. The safe rule is to keep
`AppStore.entitlements` free of comments entirely, and to validate it by
actually signing something rather than by linting:

```bash
cp /bin/echo /tmp/probe
codesign --force --sign - --entitlements macos/Runner/AppStore.entitlements /tmp/probe
```

Ad-hoc signing (`--sign -`) needs no keychain access, so this is a fast,
prompt-free check.

## Scope

Used **only** for the Mac App Store build, applied by `macos-release.yml` via
`codesign --entitlements`. `Release.entitlements` is unchanged and still covers
direct-download builds.

`codesign --entitlements <file>` signs in exactly what that file contains and
inherits nothing. A provisioning profile that *authorises* an entitlement is not
the same as the entitlement being signed into the binary.

## The keys

| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | Mandatory for the Mac App Store. If `-exportArchive` re-signs from its default entitlement set this silently disappears, which is an automatic rejection — hence the explicit `codesign` step. |
| `com.apple.security.device.audio-input` | The app's entire purpose: capturing from the microphone. |
| `com.apple.application-identifier` | `<TEAM>.<bundle id>`. Without it `altool` reports warning 90886 ("the signature … is missing an application identifier but has one in the provisioning profile"). |
| `com.apple.developer.team-identifier` | Pairs with the above. |

## Deliberately absent

- `com.apple.security.cs.allow-jit` — release builds are AOT compiled.
- `com.apple.security.network.*` — the app makes no network requests.
- `com.apple.security.files.*` — the app reads and writes no user files.

Every entitlement is something App Review can ask about; claim only what the app
actually uses.
