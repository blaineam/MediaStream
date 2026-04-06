# Security Audit Report - MediaStream

**Date:** 2026-04-06
**Scope:** Full source code review of MediaStream Swift Package
**Methodology:** Static analysis of all source files, CI/CD configurations, and dependencies

---

## Critical Findings

### 1. CRITICAL: WKWebView Grants Read Access to Entire Filesystem

**File:** `Sources/MediaStream/WebViewVideoPlayer.swift:408`

```swift
let rootAccess = URL(fileURLWithPath: "/")
webView.loadFileURL(htmlFile, allowingReadAccessTo: rootAccess)
```

In the `loadLocalVideoFallback` method, when the web view cannot write to the video's directory, it falls back to granting the WKWebView read access to the **entire filesystem root** (`/`). This means any JavaScript executing in the web view context can read any file accessible to the app process.

**Impact:** If an attacker can inject JavaScript (see finding #2), they could read arbitrary files from the device including app data, caches, and potentially credentials.

**Recommendation:** Scope `allowingReadAccessTo` to the narrowest directory containing both the HTML file and the video. Never grant access to `/`.

---

### 2. HIGH: HTML/JavaScript Injection via Unsanitized URL in Video HTML Template

**File:** `Sources/MediaStream/WebViewVideoPlayer.swift:492`

```swift
<video id="player" playsinline preload="auto" muted src="\(videoURLString)" type="\(mimeType)"></video>
```

The `videoURLString` is interpolated directly into the HTML template without escaping. While `addingPercentEncoding` is applied for local relative paths, the `else` branch uses `videoURL.absoluteString` directly. A malicious URL containing `"` or other HTML metacharacters could break out of the `src` attribute and inject arbitrary HTML/JavaScript.

Combined with finding #1, this becomes a full arbitrary file read chain on fallback paths.

**Impact:** Cross-site scripting (XSS) within the WKWebView context. Attacker-controlled media URLs could execute arbitrary JavaScript.

**Recommendation:** HTML-entity-encode all values interpolated into HTML templates, or use the DOM API (`callAsyncJavaScript`) to set the `src` attribute programmatically after the page loads.

---

### 3. HIGH: Script Injection in GitHub Actions Release Workflow

**File:** `.github/workflows/release.yml:26, 85, 117`

```yaml
VERSION="${{ github.event.inputs.version }}"
```

The `github.event.inputs.version` value is interpolated directly into shell commands via `${{ }}` expression syntax. While the semver regex provides some validation, the validation step and the steps that use the value run in **separate jobs** (the `release` job re-uses the input without re-validating). An attacker with workflow dispatch permissions could craft an input that passes the regex but exploits shell metacharacters in other contexts, or the validation could be bypassed if jobs run independently.

Additionally at lines 85, 109, and 117, the raw input is used without re-validation in shell contexts.

**Impact:** Command injection in CI/CD pipeline. An attacker with repo write access could execute arbitrary commands in the CI runner.

**Recommendation:** Use an environment variable set via the `env:` key instead of inline `${{ }}` interpolation:
```yaml
env:
  VERSION: ${{ github.event.inputs.version }}
run: |
  # Now use "$VERSION" (quoted) safely
```

---

## High Findings

### 4. HIGH: JavaScript Injection via String Interpolation in evaluateJavaScript

**File:** `Sources/MediaStream/WebViewVideoPlayer.swift:268`

```swift
let hexColor = backgroundColor.hexString
webView?.evaluateJavaScript("document.body.style.background = '\(hexColor)'; ...")
```

Multiple calls to `evaluateJavaScript` throughout the file construct JavaScript via Swift string interpolation. While `hexColor` is derived from a `Color` extension, if any code path allows user influence over these values, JavaScript injection becomes possible. This pattern is fragile and error-prone.

Other instances include seek time values, volume values, and snapshot dimensions passed to JavaScript.

**Impact:** JavaScript execution in WKWebView context if any interpolated value is attacker-controlled.

**Recommendation:** Replace `evaluateJavaScript` with `callAsyncJavaScript(_:arguments:)` which safely passes parameters without string interpolation.

---

### 5. HIGH: Decrypted Media Written to Temp Files Without Restricted Permissions

**File:** `Sources/MediaStream/MediaDownloadManager.swift:175-183`

```swift
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ms_play_\(UUID().uuidString)")
    .appendingPathExtension(originalExt)
// ...
try decryptedData.write(to: tempURL)
```

When encrypted media is decrypted for playback, the plaintext is written to the system temp directory with default file permissions. On iOS, the temp directory is within the app sandbox, but:
- No `FileProtectionType.complete` is applied, so files remain accessible while the device is locked
- The `write(to:)` call doesn't use `.completeFileProtection` option
- Cleanup relies on `pruneOldTempFiles()` and is not guaranteed on crash

Similar patterns exist in:
- `AnimatedImageHelper.swift:491` (temp GIF files)
- `WebViewVideoPlayer.swift:399` (temp HTML files)
- `ZoomableMediaView.swift:2351, 2435` (temp image files)

**Impact:** Decrypted sensitive media persists in temp directory without file protection, accessible during forensic analysis or while device is locked.

**Recommendation:** Use `.completeFileProtection` write option and implement `defer`-based cleanup:
```swift
try decryptedData.write(to: tempURL, options: [.atomic, .completeFileProtection])
```

---

## Moderate Findings

### 6. MODERATE: Encryption Migration TOCTOU Race Condition

**File:** `Sources/MediaStream/MediaDownloadManager.swift:377-432`

The `migrateEncryption` method reads, transforms, writes, then deletes the original file. If the app crashes between the write and delete, unencrypted originals remain on disk. If another part of the app reads the file between the delete and write, data loss occurs. No file locking or exclusive access is implemented.

**Recommendation:** Use atomic rename operations and file coordination (`NSFileCoordinator`) to prevent race conditions.

### 7. MODERATE: No Content Security Policy in WKWebView HTML

**File:** `Sources/MediaStream/WebViewVideoPlayer.swift:455-563`

The HTML template loaded into WKWebView has no Content-Security-Policy meta tag. Combined with the URL injection in finding #2, this means there are no restrictions on what injected scripts could do (e.g., fetch external resources, exfiltrate data).

**Recommendation:** Add a restrictive CSP:
```html
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src * blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline';">
```

### 8. MODERATE: HTTP Header Injection via Unvalidated Header Values

**Files:** `MediaDownloadManager.swift:526-529`, `WebViewAnimatedImage.swift:82-89`

Header values from `MediaStreamConfiguration.headerProvider` are set on URLRequests without validation. If header values contain CRLF sequences, HTTP header injection or response splitting could occur.

**Recommendation:** Validate that header keys and values do not contain `\r`, `\n`, or other control characters before setting them on requests.

### 9. MODERATE: Third-Party GitHub Action Not Pinned to SHA

**File:** `.github/workflows/release.yml:121`

```yaml
uses: softprops/action-gh-release@v2
```

Third-party action is referenced by mutable tag (`v2`) rather than an immutable commit SHA. A compromised upstream action could execute malicious code in the release workflow which has `contents: write` permission.

**Recommendation:** Pin to a specific commit SHA:
```yaml
uses: softprops/action-gh-release@c95fe1489396fe187066b4e7ed2388e4f1941220 # v2
```

---

## Summary

| # | Severity | Finding | File |
|---|----------|---------|------|
| 1 | **CRITICAL** | WKWebView granted read access to entire filesystem | WebViewVideoPlayer.swift:408 |
| 2 | **HIGH** | HTML injection via unsanitized URL in video template | WebViewVideoPlayer.swift:492 |
| 3 | **HIGH** | Script injection in GitHub Actions release workflow | release.yml:26 |
| 4 | **HIGH** | JS injection via string interpolation in evaluateJavaScript | WebViewVideoPlayer.swift:268 |
| 5 | **HIGH** | Decrypted media in temp files without file protection | MediaDownloadManager.swift:175 |
| 6 | MODERATE | Encryption migration TOCTOU race condition | MediaDownloadManager.swift:377 |
| 7 | MODERATE | No Content Security Policy in WKWebView HTML | WebViewVideoPlayer.swift:455 |
| 8 | MODERATE | HTTP header injection via unvalidated values | MediaDownloadManager.swift:526 |
| 9 | MODERATE | Third-party GitHub Action not pinned to SHA | release.yml:121 |
