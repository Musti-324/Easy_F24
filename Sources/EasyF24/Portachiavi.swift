import Foundation
import Security

/// Salva e legge dati riservati nel Portachiavi di macOS.
enum Portachiavi {
    static func leggi(servizio: String, account: String) -> Data? {
        var query = base(servizio: servizio, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var risultato: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &risultato) == errSecSuccess else { return nil }
        return risultato as? Data
    }

    @discardableResult
    static func salva(_ dati: Data, servizio: String, account: String) -> Bool {
        let query = base(servizio: servizio, account: account)
        let stato = SecItemUpdate(query as CFDictionary, [kSecValueData as String: dati] as CFDictionary)
        guard stato == errSecItemNotFound else { return stato == errSecSuccess }
        var nuovo = query
        nuovo[kSecValueData as String] = dati
        nuovo[kSecAttrLabel as String] = servizio
        return SecItemAdd(nuovo as CFDictionary, nil) == errSecSuccess
    }

    static func elimina(servizio: String, account: String) {
        SecItemDelete(base(servizio: servizio, account: account) as CFDictionary)
    }

    private static func base(servizio: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servizio,
            kSecAttrAccount as String: account,
        ]
    }
}
