# Validation evidence

Validated locally on macOS arm64 on 2026-10-15, using the shared Flutter 3.47.7 / Dart 3.13.5 SDK. This report distinguishes executable evidence from untested platform and hardware behavior.

| Gate | Result |
| --- | --- |
| `flutter analyze` | Passed: no issues |
| `flutter test` | Passed: 20 tests using temporary synthetic fixtures |
| Dart CLI AOT build | Passed with `dart build cli --output build/cli --target bin/nsusbloader.dart` |
| Compiled CLI file operations | Scan, split and merge passed; 4,097 bytes preserved exactly |
| Read-only libusb discovery | Passed with local libusb; zero matching devices; no interface claim or data transfer |
| Title DB live smoke | CN.zh imported into 89 display-only records; conditional refresh completed |
| Official release API live smoke | Blocked by GitHub unauthenticated API rate limit (HTTP 403), not an application success |
| macOS Flutter desktop build | Blocked: full Xcode is not installed; Command Line Tools are selected |
| Linux / Windows builds | Not executed on this macOS host; CI matrix provided, not run remotely |
| Physical Awoo USB/network installation | Not performed or authorized |
| Physical RCM injection/boot | Not performed or authorized |

The 4,097-byte CLI fixture's SHA-256 was `a16560d668b843fb3be99ace41dbd18471f342bd3255a1d21204b35e43f74436`. Temporary source/output files were removed after the check. The native CLI bundle is retained under ignored `build/cli/bundle/`; it is not a desktop GUI bundle.

## Automated coverage

- Exact random access across split boundaries; valid EOF, invalid ranges, missing/unequal/empty/link segments, source changes, output preservation and cancellation cleanup.
- Base/update/DLC grouping, multiple formats, visible orphan content, filename identity, plaintext PFS0/CNMT identity priority, duplicate roots, skipped symlink loops and manual override reset.
- Title DB ID mapping and display allowlist; raw input remains in memory. Conditional refresh and persisted language/fallback preferences are checked.
- Loopback HTTP tests with a fake console: big-endian advertisement framing, binding before advertisement, duplicate filenames, full GET, HEAD, standard/open/suffix ranges, split ranges, 404/405/416 responses, interval deduplication and cancellation.
- Awoo USB with a fake transport: list and reply framing, requested split-file bytes, allowlist/range rejection, exit semantics. RCM frame layout, odd packet count, payload continuation, identity rejection and cancellation are checked without opening USB.
- Official release asset selection, download bounds, gzip decoding, size and SHA-256 validation, existing-cache preservation on failure, ETags and cancellation cleanup use local fixtures. Live Hekate/fusee asset download was not validated because release discovery was rate-limited.
- Flutter widget tests exercise per-game content groups, selection into queue, all navigation pages, and a 430-pixel-wide layout. Screenshots are rendered widget artifacts at 1440×1000, not evidence of a running native desktop binary.

## Reproduce screenshots

```sh
FLUTTER_ROOT=/path/to/existing/flutter NSUSB_SCREENSHOTS=1 \
  flutter test test/ui_test.dart
```

The test loads fonts from the existing SDK for readable raster output. Only original synthetic titles and procedural artwork appear; no personal desktop or network game artwork is captured. The rendered library and content-selection screenshots were visually inspected.

## Resource boundaries

No Nix evaluation, Rust build, OS update, device injection or console installation was run. The shared Flutter SDK was reused; the attempted macOS build populated its missing standard macOS engine artifacts. That shared SDK is preserved. Project test caches are disposable; the CLI bundle and screenshot evidence are retained. No changes were made to nsp-dawrin, its active processes, compatibility symlinks, runtime data or NAS mount.
