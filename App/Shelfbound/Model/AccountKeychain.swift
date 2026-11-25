import Foundation
import Security

/// A site the person signed in to from a source's account screen. The username is shown
/// in Settings and handed to the source; the site's cookies live in the Keychain.
struct SavedAccount: Codable, Hashable {
    var username: String
    var signedInAt: Date
    /// Account lists (by ID) whose new works join the library on each update check.
    var syncedLists: [String] = []
}

/// Keeps a signed-in site's cookies in the Keychain, one item per source, so the session
/// survives app restarts without a password ever being stored. At launch they're copied
/// back into the shared cookie store that every request uses.
enum AccountKeychain {
    private static let service = "app.shelfbound.accounts"

    /// A cookie's fields, since `HTTPCookie` itself isn't Codable.
    private struct StoredCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sameSite = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }

    static func save(_ cookies: [HTTPCookie], for sourceID: String) {
        guard let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)) else { return }
        delete(for: sourceID)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID,
            kSecValueData as String: data,
            // Background update checks run while the phone is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(for sourceID: String) -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data)
        else { return [] }
        return stored.compactMap(\.cookie).filter { ($0.expiresDate ?? .distantFuture) > Date() }
    }

    static func delete(for sourceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Cookies in `cookies` that a request to one of `domains` would send.
    static func cookies(_ cookies: [HTTPCookie], matching domains: [String]) -> [HTTPCookie] {
        cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return domains.contains { pattern in
                let base = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
                let host = base.lowercased()
                return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("." + host)
            }
        }
    }
}
