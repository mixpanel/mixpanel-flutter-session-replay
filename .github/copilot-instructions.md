# Copilot Coding Agent Instructions

## Project Overview

This is the **Mixpanel Flutter Session Replay SDK** — a Flutter plugin that captures UI screenshots, user interactions, and app lifecycle events, then uploads them to the Mixpanel Session Replay backend. It supports iOS 13+, Android API 24+, and macOS 10.15+.

**Current stage:** Beta (v0.1.0-beta.1)

## Technology Stack

- **Dart 3.8+**, **Flutter 3.38+**
- SQLite (`sqflite`) for local event persistence
- HTTP (`http`) for backend communication
- Platform channels for native image compression (Android/iOS/macOS)

## Repository Layout

```
lib/src/                        # SDK source code (public API + internals)
  session_replay.dart           # Main public API class
  session_replay_options.dart   # Configuration options
  version.dart                  # Version constant
  models/                       # Data models (config, events, sessions)
  internal/                     # Coordinator, recording, storage, upload
  widgets/                      # Widget layer (lifecycle, masking, frame monitoring)
test/                           # Unit tests + golden tests
  helpers/                      # Test fakes (HTTP, connectivity, event queue, coordinator)
  golden/                       # Golden image reference PNGs
example/                        # Demo app
  integration_test/             # On-device integration tests
  lib/                          # Example app source
tool/                           # Build scripts (bump_version.sh)
.github/workflows/              # CI/CD (ci.yml, release, prepare-release)
```

## Essential Commands

Flutter and Dart are pre-installed by `.github/workflows/copilot-setup-steps.yml`. You can run all standard commands directly.

```bash
# Unit tests
flutter test

# Unit tests excluding golden tests (for compat-check on older Flutter)
flutter test --exclude-tags=golden

# Format check — ALWAYS use --language-version=latest (tall style)
dart format --language-version=latest --set-exit-if-changed .

# Static analysis — treats all infos/hints as errors
dart analyze --fatal-infos

# Integration tests (requires connected device/simulator)
cd example && flutter test integration_test/run_all_test.dart -d <device_id>

# Integration tests with Mixpanel token (for live settings test)
cd example && flutter test integration_test/run_all_test.dart \
  --dart-define=MIXPANEL_TOKEN=$MIXPANEL_TOKEN -d <device_id>
```

## CI Pipeline (`.github/workflows/ci.yml`)

CI runs on push to `main` and all PRs. Five jobs:

| Job | Runner | Flutter | What it does |
|-----|--------|---------|--------------|
| `compat-check` | macOS | 3.38.0 | Min-version analysis + unit tests (excluding golden) |
| `build` | macOS | 3.41.2 | Format check, analysis, unit tests with coverage |
| `test-ios` | macOS | 3.41.2 | Integration tests on iOS Simulator |
| `test-android` | Ubuntu | 3.41.2 | Integration tests on Android API 24 + 34 |
| `test-macos` | macOS | 3.41.2 | Integration tests on macOS Desktop |

Integration test jobs (`test-ios`, `test-android`, `test-macos`) depend on `compat-check` and `build` passing first.

### CI Formatting Check

CI uses a git-diff based format check (not `--set-exit-if-changed`):
```bash
dart format --language-version=latest .
if [ -n "$(git diff --name-only)" ]; then exit 1; fi
```
Always use `--language-version=latest` when formatting to match CI.

## Code Style

- Follow standard Dart/Flutter conventions
- Use `dart format --language-version=latest` (tall style formatting)
- Linting: `package:flutter_lints/flutter.yaml` with `--fatal-infos`
- Match existing comment style — don't add comments unless they match surrounding code or explain something complex

## Architecture (Key Concepts)

The SDK has a layered architecture:

1. **Public API** — `MixpanelSessionReplay` (static `initialize()` factory, instance methods)
2. **Widget Layer** — `MixpanelSessionReplayWidget` wraps the user's app with: `LifecycleObserver` → `InteractionDetector` → `FrameMonitor` → `RepaintBoundary` → user's app
3. **Coordinator** — `SessionReplayCoordinator` orchestrates all internal components
4. **Components** — `ScreenshotCapturer`, `EventRecorder`, `UploadService`, `SettingsService`, `SessionManager`
5. **Storage** — `EventQueue` (SQLite-backed with quota enforcement)

See `ARCHITECTURE.md` for full diagrams.

## Performance Rules (Critical)

### Never Walk Up the Render Tree
Start at the top, traverse downward. Pass data (`viewportBounds`, `tickerEnabled`) through traversal parameters. This ensures O(n) instead of O(n × tree_depth).

- **DO:** Pass context down through parameters
- **DON'T:** Use `node.parent` loops or `findAncestorWidgetOfExactType()`

### Order Conditional Checks Fastest to Slowest
1. Type checks (`is RenderBox`)
2. Property access (`hasSize`, `attached`)
3. Method calls (`isEmpty`, `overlaps()`)
4. String operations (`toString()`, `contains()`)

## Testing Conventions

### Unit Tests (`test/`)

- **Given-When-Then** pattern for all tests
- **Single responsibility** — one behavior per test
- **Real instances over mocks** — only mock external dependencies (HTTP, platform channels)
- **No real delays** — use `fakeAsync` where possible
- **Golden tests** use the `@Tags(['golden'])` annotation and are skipped on older Flutter versions

### Test Helpers (`test/helpers/`)

| Helper | Purpose |
|--------|---------|
| `fake_http_client.dart` | Fixed-response, recording, failing HTTP clients |
| `fake_connectivity.dart` | Mock connectivity without platform channels |
| `in_memory_event_queue.dart` | In-memory SQLite replacement |
| `fake_widget_coordinator.dart` | Widget/UI layer mock with call tracking |

### Integration Tests (`example/integration_test/`)

- Run on real devices/simulators via `run_all_test.dart` entry point
- Use `waitForAutomaticCapture()` helper (2s timeout for capture pipeline)
- Use 2s rate-limit gaps between captures (CI emulators are slow)
- Support `--dart-define=LOG_LEVEL=debug` for verbose output
- Support `--dart-define=MIXPANEL_TOKEN=<token>` for live settings tests

### Do Not Modify Production Code for Tests

If a test is difficult to write due to hard-coded dependencies — stop and discuss. Don't add injection points or change internal structure just for testability.

## Reviewed Design Decisions

These decisions have been reviewed and accepted. **Do not re-raise them in code reviews:**

1. `StateError` if `add()` called before `initialize()` — catches internal misuse
2. Settings check failure stops recording without flush — events are persisted to SQLite
3. Persistent frame callback cannot be removed — Flutter limitation, guarded with `if (!mounted) return`
4. `stopRecording()` flush is fire-and-forget — events persisted before flush
5. Concurrent flush during periodic timer — handled by `_isFlushing` guard
6. `FrameMonitor` capture not awaited — `_isCaptureInProgress` flag prevents overlap
7. Dispose order and active uploads — `dispose()` awaits `flush()` via `_flushCompleter`
8. HTTP client connections on timeout — managed by `http.Client` internally
9. Touch coordinates recorded for masked elements — coordinates only, visual content is masked
10. Non-atomic batch removal — queue cleared via `removeAll()` on init
11. No image dimension validation — dimensions from `RenderRepaintBoundary.toImage()` (hardware-bounded)
12. Silent failures in `EventRecorder` — graceful degradation, SDK must never crash host app
13. No double-dispose protection — fixed with `_isDisposed` guards

## Masking & Security

- **TextFields are ALWAYS masked** regardless of configuration — this is a security invariant
- Auto-masking covers text and image views by default (`autoMaskedViews: {text, image}`)
- Manual masking: `MixpanelMask` and `MixpanelUnmask` widgets
- Golden tests validate masking behavior — check `test/masking_golden_test.dart`

## Version Management

Version is tracked in three places (kept in sync by `tool/bump_version.sh`):
1. `pubspec.yaml` — `version: X.Y.Z`
2. `lib/src/version.dart` — `const String sdkVersion = 'X.Y.Z-flutter'`
3. `README.md` — dependency version in installation instructions

## Common Pitfalls

1. **Formatting without `--language-version=latest`** will produce different output than CI and fail the format check
2. **Running golden tests on an incompatible Flutter version** will fail — these are tagged and excluded in `compat-check`
3. **`pubspec.lock` is gitignored** — this is a library, not an application. Don't commit lock files.
4. **Integration tests require a device** — they cannot run in headless/unit-test mode
5. **The example app uses a local path dependency** to the SDK (`path: ../` in `example/pubspec.yaml`)
