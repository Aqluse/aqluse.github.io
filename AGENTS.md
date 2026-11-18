# AGENTS.md

Personal portfolio website of a Flutter developer, built with Flutter Web and published
to https://aqluse.github.io via GitHub Pages.

## Flutter version — use FVM

- Run Flutter/Dart through FVM: `fvm flutter …`, `fvm dart …` — not a global `flutter`. The version
  is pinned in `.fvmrc`.
- CI reads the same version from `.fvmrc` (`flutter-version-file` in
  `.github/workflows/deploy.yml`), so `.fvmrc` is the single place to change it.

## Deployment gotchas

- The `deploy` workflow runs on every push to `master`, and every run publishes to production
  (GitHub Pages). Never push to `master` unless explicitly asked.
- `<base href="$FLUTTER_BASE_HREF">` in `web/index.html` is a placeholder filled in by `--base-href`
  during the CI build. Do not hardcode it.
- The app uses path URLs (`usePathUrlStrategy`). GitHub Pages has no SPA fallback, so the workflow
  copies `index.html` to `404.html` after the build; without it, deep links and reloads show
  GitHub's 404 page. Keep this step while path URLs are used.
- The current navigation (`lib/navigation/`) is temporary.

## Code style

- Dart SDK ^3.11. The code uses dot shorthands (`.fromSeed(...)`, `.center`); keep them, don't
  expand them to the full form.
- Lints come from `flutter_lints` (pinned to an exact version; to be replaced by a personal lints
  package later). `fvm flutter analyze` must report no issues.
- Web is the only target platform; `windows/` exists for local debugging only. Don't generate
  `android/`, `ios/`, or other platform folders (use `--platforms=web` with `flutter create`).
- Write code comments in English. Comments that aren't purely English (another language or mixed)
  were written by the owner: leave them as they are unless asked.
- The name and description in `web/manifest.json` are intentional; don't change them (or the colors)
  unless asked.

## Localization

- Built-in `gen-l10n`, configured in `l10n.yaml`. English only for now.
- Strings live in `assets/localizations/intl_en.arb`; access them via `S.of(context)`.
- Generated code in `lib/generated/localization/` is committed: after changing the ARB, run
  `fvm flutter gen-l10n` and commit both.
- Brand names (GitHub, Telegram, HeadHunter, LinkedIn) are not localized.
- `intl: any` is intentional: the version is dictated by `flutter_localizations` in the SDK.

## App icons

- `web/favicon.svg` is the single source of the app icon in every platform folder (`web/`,
  `windows/`, and any added later).
- When it changes, regenerate every rendition of the app icon (favicon, launcher/PWA icons,
  executable icon) in all platform folders; don't assume the list is the one you remember. Leave
  other icons and images (UI, brand logos) untouched.
- App icons are transparent, except maskable ones: white background, artwork scaled to fit the safe
  zone. Follow each platform's own icon conventions.

## Git

- Commit messages follow Conventional Commits: `feat: …`, `fix: …`, `chore: …`.
- The main branch is `master`; every push to it triggers the production deploy (see Deployment
  gotchas).

## Verifying changes

- `fvm flutter analyze`
- `fvm flutter build web` — must succeed, same as CI.
- Local preview: `fvm flutter run -d chrome`
- No tests yet: `test/widget_test.dart` is the Flutter template and doesn't test the app. Once real
  tests are written, run `fvm flutter test`.

## Performance measurements

- Measure `--profile` builds. `fvm flutter run -d chrome` uses CanvasKit (dart2js); `--wasm` uses
  skwasm. GitHub Pages can't send COOP/COEP headers, so skwasm runs single-threaded there; measure
  skwasm from a static build served without those headers, not from `flutter run` (multi-threaded).
- Keep the measured Chrome window focused: Chrome throttles unfocused or occluded windows, and the
  `--disable-*-throttling` / `--disable-backgrounding-occluded-windows` flags don't prevent it.
- `flutter run --web-browser-flag` splits values on commas (`--window-size=1,2` breaks); start
  Chrome yourself (`-d web-server`) when a flag needs commas.
- FPS is capped by the display refresh rate; compare variants below the cap (e.g. raise the bubble
  count), and report the display used.
