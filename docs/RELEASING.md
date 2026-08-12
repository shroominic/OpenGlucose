# Releasing OpenGlucose

This repo ships two GitHub Actions workflows:

- **`.github/workflows/ci.yml`** — the PR quality gate. On every pull request and
  push to `main` it runs `flutter pub get`, `dart format --set-exit-if-changed`,
  `flutter analyze`, `flutter test --coverage`, and build sanity checks
  (`flutter build apk --debug`, `flutter build ios --no-codesign`).
- **`.github/workflows/release.yml`** — builds and publishes signed releases.
  It triggers on `v*` git tags (or manual `workflow_dispatch`) and has two jobs:
  - **Android** — builds a signed release APK + AAB and attaches them to the
    GitHub Release.
  - **iOS** — builds a signed IPA and uploads it to TestFlight.

The Flutter app lives in `openhealth/`. The Flutter version is pinned via the
`FLUTTER_VERSION` env in each workflow — keep it in sync with the
`environment.flutter` constraint in `openhealth/pubspec.yaml`.

## Graceful gating

Both release jobs **skip with a warning instead of failing** when their required
secrets are not configured. This means the workflows merge and are ready to go;
they activate automatically once the secrets below are added in
**Settings → Secrets and variables → Actions**.

---

## Required GitHub secrets

### Android signing (enables the Android job)

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded upload/release keystore (`.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore (store) password |
| `ANDROID_KEY_ALIAS` | Key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | Password for that key alias |

**Generate the keystore** (do this once, keep the file safe and out of git):

```bash
keytool -genkey -v \
  -keystore openglucose-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias openglucose
# You will be prompted for the store password, key password and a distinguished name.
```

**Base64-encode it for the secret:**

```bash
base64 -i openglucose-release.jks | pbcopy   # macOS, copies to clipboard
# or: base64 -w0 openglucose-release.jks      # Linux, single line to stdout
```

Paste that into `ANDROID_KEYSTORE_BASE64`, then set
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (e.g. `openglucose`) and
`ANDROID_KEY_PASSWORD` to match what you entered.

> **One-time app change still required for a *signed* APK.**
> The release workflow decodes the keystore to
> `android/app/release-keystore.jks` and writes `android/key.properties` with
> `storePassword` / `keyPassword` / `keyAlias` / `storeFile=release-keystore.jks`.
> For Gradle to actually use them, `openhealth/android/app/build.gradle.kts`
> must load `key.properties` and reference it from the `release` signing
> config (it currently signs with the debug keystore — see the `TODO` there).
> The CI/release workflows intentionally do not modify app source. Add a block
> like the following to `build.gradle.kts` once:
>
> ```kotlin
> import java.util.Properties
> import java.io.FileInputStream
>
> val keystoreProperties = Properties()
> val keystorePropertiesFile = rootProject.file("key.properties")
> if (keystorePropertiesFile.exists()) {
>     keystoreProperties.load(FileInputStream(keystorePropertiesFile))
> }
>
> android {
>     signingConfigs {
>         create("release") {
>             if (keystorePropertiesFile.exists()) {
>                 keyAlias = keystoreProperties["keyAlias"] as String
>                 keyPassword = keystoreProperties["keyPassword"] as String
>                 storeFile = file(keystoreProperties["storeFile"] as String)
>                 storePassword = keystoreProperties["storePassword"] as String
>             }
>         }
>     }
>     buildTypes {
>         release {
>             signingConfig = if (keystorePropertiesFile.exists())
>                 signingConfigs.getByName("release")
>             else
>                 signingConfigs.getByName("debug")
>         }
>     }
> }
> ```
>
> Until that block is added, the release APK/AAB are produced but signed with
> the debug key (not Play-Store-uploadable).

### iOS / TestFlight (enables the iOS job)

| Secret | What it is |
| --- | --- |
| `APPSTORE_API_KEY_ID` | App Store Connect API **Key ID** |
| `APPSTORE_API_ISSUER_ID` | App Store Connect API **Issuer ID** |
| `APPSTORE_API_KEY_BASE64` | Base64 of the `AuthKey_XXXX.p8` private key |

**Generate the App Store Connect API key:**

1. Go to [App Store Connect → Users and Access → Integrations → App Store
   Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Create a key with the **App Manager** role (needed to upload builds).
3. Copy the **Issuer ID** (top of the page) → `APPSTORE_API_ISSUER_ID`.
4. Note the new key's **Key ID** → `APPSTORE_API_KEY_ID`.
5. Download the `AuthKey_<KeyID>.p8` file (downloadable **only once**), then:

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # macOS
   # or: base64 -w0 AuthKey_XXXXXXXXXX.p8      # Linux
   ```

   Paste into `APPSTORE_API_KEY_BASE64`.

The iOS job exports the IPA with `ios/ExportOptions.plist` (already committed:
`app-store` method, automatic signing, team `YLK778Z528`) and uploads via
`xcrun altool` using the API key. The API key lets the macOS runner fetch
signing assets, so no manual certificate/profile management is needed.

> **Optional — manual signing.** If automatic signing does not work in CI for
> your account, add `IOS_DIST_CERT_BASE64`, `IOS_DIST_CERT_PASSWORD` and
> `IOS_PROVISIONING_PROFILE_BASE64`, import them into a temporary keychain in
> the job, and switch `ExportOptions.plist` `signingStyle` to `manual`.

---

## Cutting a release

1. Make sure `main` is green (CI passing).
2. Bump the app version in `openhealth/pubspec.yaml`
   (`version: x.y.z+<build>`). The `+<build>` number must increase for each
   TestFlight upload.
3. Tag and push:

   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

4. The **Release** workflow runs automatically:
   - Android → signed APK + AAB attached to the GitHub Release for tag `v1.2.3`.
   - iOS → IPA uploaded to TestFlight (then processed by Apple; add it to a
     TestFlight group in App Store Connect to distribute to testers).

You can also trigger it manually from **Actions → Release → Run workflow**
(no Release assets are attached on a manual run since there is no tag, but the
TestFlight upload and workflow artifacts still happen).
