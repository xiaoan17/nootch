import Foundation

extension Bundle {
    /// Bundle that holds our packaged assets (SVG provider logos, NootchIcon.png).
    ///
    /// SwiftPM autogenerates `Bundle.module` for our `Resources/` folder, but its
    /// generated accessor only checks `Bundle.main.bundleURL/nootch_Nootch.bundle`
    /// (the .app root). Placing the resource bundle at the .app root violates
    /// Apple's bundle layout and makes `codesign` reject the app with "unsealed
    /// contents present in the bundle root". So we ship it at the canonical
    /// `Contents/Resources/` location and route lookups here first.
    ///
    /// Fallback order:
    /// 1. `.app/Contents/Resources/nootch_Nootch.bundle` — shipped release
    /// 2. `Bundle.module` — SwiftPM's bundle, used during `swift run` and tests
    static let nootchResources: Bundle = {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/nootch_Nootch.bundle")
        if let bundle = Bundle(url: embedded) { return bundle }
        return .module
    }()
}
