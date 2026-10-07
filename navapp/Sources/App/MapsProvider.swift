import Foundation
import GoogleMaps
import Security

enum MapsSource: String, CaseIterable, Identifiable {
    case apple, google

    var id: Self { self }

    var label: String {
        switch self {
        case .apple: String(localized: "Apple + Valhalla")
        case .google: String(localized: "Google")
        }
    }
}

/// Which maps the app uses: Apple's map and search with Valhalla routes, or Google's map,
/// search and routes with the rider's own API key. Google is used only once the key has
/// passed a test; until then, or when it fails, the app stays on Apple.
@MainActor
final class MapsProvider: ObservableObject {
    static let shared = MapsProvider()

    enum KeyStatus: Equatable {
        case missing, testing, valid
        case invalid(String)
    }

    @Published var source: MapsSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "mapsSource") }
    }
    @Published private(set) var key: String?
    @Published private(set) var keyStatus: KeyStatus

    /// The key given to the Maps SDK. The SDK takes one per launch, so a key changed
    /// afterwards needs the app restarted (`needsRestart`).
    private var sdkKey: String?

    /// Google's map, search and routes are in use.
    var usesGoogle: Bool { source == .google && keyStatus == .valid && key != nil && sdkKey == key }

    var needsRestart: Bool { source == .google && keyStatus == .valid && sdkKey != nil && sdkKey != key }

    /// "••••987922": enough to tell keys apart without showing one off.
    var maskedKey: String? { key.map { "••••" + $0.suffix(6) } }

    private init() {
        source = MapsSource(rawValue: UserDefaults.standard.string(forKey: "mapsSource") ?? "") ?? .apple
        key = Keychain.read()
        keyStatus = key == nil ? .missing : UserDefaults.standard.bool(forKey: "googleKeyValid") ? .valid : .invalid("")
        provideSDKKey()
    }

    /// Saves and tests a key; an empty one removes it.
    func setKey(_ text: String) async {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else {
            Keychain.delete()
            key = nil
            keyStatus = .missing
            UserDefaults.standard.set(false, forKey: "googleKeyValid")
            return
        }
        Keychain.save(new)
        key = new
        keyStatus = .testing
        let problem = await GoogleMapServices.test(key: new)
        guard key == new else { return }  // replaced while testing
        keyStatus = problem.map { .invalid($0) } ?? .valid
        UserDefaults.standard.set(problem == nil, forKey: "googleKeyValid")
        provideSDKKey()
    }

    private func provideSDKKey() {
        guard sdkKey == nil, keyStatus == .valid, let key else { return }
        GMSServices.provideAPIKey(key)
        sdkKey = key
    }
}

/// The Google key, in the Keychain rather than the app's preferences.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PebbleOpenNav.google",
        kSecAttrAccount as String: "apiKey",
    ]

    static func read() -> String? {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock  // routes while locked
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
