# Trel iOS SDK

Crashes, app hangs, handled errors, breadcrumbs, sessions, network spans and logs for iOS, tvOS
and macOS — sent to [Trel](https://trel.to) over OTLP. Crash capture is built on
[KSCrash](https://github.com/kstenerud/KSCrash) (Mach, signal, C++, NSException, Swift traps).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/waytodev/trel-ios.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'Trel', '~> 0.1'
```

```swift
import Trel

@main
struct ShopApp: App {
    init() {
        Trel.start(TrelOptions(apiKey: "trel_sk_…", environment: "production"))
    }
}
```

## What is captured

| Signal | Mechanism | How |
| --- | --- | --- |
| Crashes | `crash` | KSCrash writes the report at crash time; converted to an Apple-format stack + binary images (`trel.debug_meta`) and sent on next launch |
| App hangs | `app_hang` | Main-thread watchdog (2 s default) with the main thread's stack; the app is alive so severity is ERROR |
| Handled errors | `handled` | `Trel.capture(error)` |
| Sessions | — | `started` per launch, `errored` on first handled error, `crashed` on next launch after a crash → crash-free rate per release |
| Breadcrumbs | — | App state, memory warnings, `viewDidAppear`, `URLSession` requests, `Trel.addBreadcrumb` (last 100; attached to every exception, free) |
| HTTP spans | — | `URLSession` swizzle (`enableNetwork`) or `Trel.startHttpSpan(method:url:)` |
| Logs | — | `Trel.log(.warn, "…")` (billed as events) |

## API

```swift
Trel.capture(error, attributes: ["order_id": id])
Trel.captureMessage("checkout skipped", level: .warn)
Trel.addBreadcrumb("Tapped Pay", category: "user")
Trel.setUser(id: "u_42", email: "a@b.co")
Trel.setTag("tier", "gold")
Trel.log(.info, "cache warmed", attributes: ["items": 120])
Trel.flush()
```

`TrelOptions`: `apiKey`, `environment`, `release` (default `CFBundleShortVersionString+CFBundleVersion`),
`service` (default bundle id), `endpoint`, `enableCrashReporting`, `enableAppHangs`, `appHangTimeout`,
`enableNetwork`, `enableNetworkBreadcrumbs`, `enableViewControllerBreadcrumbs`, `breadcrumbsAsLogs`,
`maxBreadcrumbs`, `minLogLevel`, `debug`, `beforeSend`.

## Delivery

Everything goes to `Application Support/trel/queue/` first, then to `https://ingest.trel.to`
(gzip OTLP/JSON) on start, 2 s after new records, every 30 s in the foreground, and on background
(inside a background task). 5xx / 429 back off exponentially; 402 (plan limit) stops sending for
the process. The queue is capped at 200 files / 8 MB; crash envelopes are never trimmed.

## Symbols (dSYM)

Stacks arrive as `image + address` with binary-image UUIDs. Upload dSYMs per release so Trel can
match them (symbolication of Apple frames is being rolled out; files are stored and listed today):

```sh
# Xcode → Build Phases → Run Script (release builds)
npx @trel-to/cli symbols upload "$DWARF_DSYM_FOLDER_PATH" --kind dsym \
  --release "$MARKETING_VERSION+$CURRENT_PROJECT_VERSION" --key "$TREL_KEY"
```

## Publishing (maintainers)

SPM needs `Package.swift` at the repository root, so the SDK is mirrored to
`github.com/waytodev/trel-ios` with `git subtree`:

```sh
# from the monorepo root, clean tree: pushes main and tags v<s.version> on the mirror
pnpm mirror:sdks ios

# CocoaPods (after the tag exists on the mirror)
pod trunk push packages/sdk-ios/Trel.podspec --allow-warnings
```

Bump `sdkVersion` in `Sources/Trel/Trel.swift` and `s.version` in `Trel.podspec` together.

Local check: `swift build` (macOS) and
`xcodebuild -scheme Trel -destination 'generic/platform=iOS Simulator' build`.
