# MediaStreamDemo — SCA gallery demo + XCUITest harness

A small iOS app that hosts the MediaStream gallery against a **stubbed**
sensitive-content policy so every Sensitive Content Awareness (SCA) + gallery
feature is drivable **headlessly on the iOS Simulator** — no physical device, no
real `SensitiveContentAnalysis`, no real Declared Age Range sheet.

## Why

MediaStream's SCA used to be verifiable only by testing live on a device. This
demo + XCUITest suite makes the core gallery + SCA behavior assertable in CI.

## Layout

- `project.yml` — XcodeGen spec. The `.xcodeproj` is **generated** (and
  git-ignored); regenerate it before building.
- `MediaStreamDemo/` — the demo app.
  - `DemoTile.swift` — generates numbered color tiles so blur/reveal is obvious.
  - `DemoMediaItem.swift` — a `MediaItem` + `SensitiveOverlayItem` tile.
  - `DemoSensitiveStore.swift` — the **stub** policy; vends a
    `SensitiveOverlayController` from launch arguments / in-app controls.
  - `DemoRootView.swift` — harness UI (age/flag pickers, open/close) + launch-arg
    deep links into grid / slideshow.
- `MediaStreamDemoUITests/` — the XCUITest suite (`MediaStreamSCAUITests`).

## Running

```sh
cd Example
xcodegen generate
# Pick any booted iPhone simulator UDID (xcrun simctl list devices)
xcodebuild test \
  -project MediaStreamDemo.xcodeproj \
  -scheme MediaStreamDemo \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath build/dd \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

CI runs exactly this in the `demo-uitests` job (see `.github/workflows/ci.yml`).

## Launch arguments

| Argument        | Values                                    | Default        |
|-----------------|-------------------------------------------|----------------|
| `-scaAge`       | `verifiedAdult` `undetermined` `minor`    | `verifiedAdult`|
| `-scaFlag`      | `all` `some` `none`                       | `some`         |
| `-scaItems`     | integer                                   | `12`           |
| `-scaStart`     | `grid` `slideshow`                        | `grid`         |
| `-scaStartIndex`| integer (slideshow start)                 | first sensitive|

`-scaFlag some` flags only a **minority** of items (tiles 1 & 3) so the count
stays below `SensitiveBulkPolicy` and the **per-item** shield is reachable;
`-scaFlag all` flags every item so the **bulk block** fires.

## What the suite covers

1. **Per-item shield** — minority sensitive + verified adult → each sensitive
   cell shows "Show Anyway"; a single tap reveals THAT cell; the button does not
   reappear on a revealed cell; other cells stay shielded.
2. **Bulk block** — majority sensitive → one block + Reveal All; a single tap
   reveals all; a Done control stays reachable and dismisses the gallery while
   the block is shown.
3. **Age gating** — verified-adult sees reveal; undetermined sees Verify Age;
   minor sees neither (but can still dismiss).
4. **Slideshow** — reveal works in the full-screen viewer and its button does
   not overlap the bottom transport controls.
5. **Reveal scoping** — dismissing + reopening the gallery shows content blurred
   again (reveal does not persist).
