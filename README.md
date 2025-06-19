# LicenseSeat Swift SDK

> A delightful, first-class Swift package for integrating **LicenseSeat** licensing into macOS, iOS, tvOS & watchOS apps.

LicenseSeat's mission is to make commercial licensing for indie developers *effortless*. This SDK brings those same values—simplicity, robustness, and stellar DX—to the Swift ecosystem.

---

## ✨ Features (today)

* Modern, async/await-first API surface.
* Runs on macOS 12+, iOS 13+, tvOS 13+, watchOS 8+.
* Zero external runtime dependencies.
* Comprehensive doc-comment coverage (generate with Swift-DocC).

> **Heads-up**
> This is **work-in-progress**. The public interface you see now is forward-compatible, but most operations are stubbed. Follow the [road-map](#roadmap) to see what's coming next.

---

## 🚀 Installation

```swift
.package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.1.0")
```

Then add `"LicenseSeatSDK"` to your target's dependencies:

```swift
dependencies: [
    .product(name: "LicenseSeatSDK", package: "licenseseat-swift")
]
```

---

## 🛠  Basic usage

```swift
import LicenseSeatSDK

@MainActor
func bootstrapLicense() async {
    do {
        var client = LicenseSeat.shared
        try await client.activate(licenseKey: "YOUR-LICENSE-KEY")
        print("Activated! 🎉")
    } catch {
        // TODO: handle errors
    }
}
```

Full-fledged examples will ship once the networking layer lands.

---

## 📚 Documentation

Generate local documentation with Swift-DocC:

```bash
swift package --allow-writing-to-directory ./Docs \
    generate-documentation --output-path ./Docs
```

> After generation, open `Docs/index.html` in your browser.

---

## 🗺 Roadmap

* [ ] HTTP client & retries
* [ ] Secure, offline-friendly caching layer
* [ ] Cryptographic receipt validation
* [ ] License seat management (transfer / release)
* [ ] Rich error types & recovery suggestions
* [ ] Example Mac app
* [ ] SwiftUI sample with in-app activation flow

---

## 🤝 Contributing

PRs & feedback are welcome! Please open an issue first if you plan a substantial change—let's ensure it aligns with the project direction.

---

## License

Licensed under the MIT license. See [`LICENSE`](LICENSE) for details. 