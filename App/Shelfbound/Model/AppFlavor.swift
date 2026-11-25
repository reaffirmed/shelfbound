import Foundation

/// Which build this is. The App Store build is compiled with `APP_STORE` (the
/// "Shelfbound App Store" scheme, or `xcodebuild -configuration AppStore`); the
/// sideload build that GitHub Actions packages as an IPA is not.
///
/// Both builds ship with no sources and no repos. The App Store build only adds
/// what review needs: an age check before explicit sources show, and no tools aimed
/// at moving a library over from sideloaded readers.
enum AppFlavor {
    #if APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// Where the privacy policy lives, linked from Settings and the App Store listing.
    static let privacyPolicyURL = URL(string: "https://github.com/reaffirmed/shelfbound/blob/main/docs/app-store/privacy-policy.md")!
}
