import Foundation
import Security
import LocalAuthentication

let cacheService = "dev.bambam.QuotaGarden.ClaudeSession"
let interactive = CommandLine.arguments.contains("--connect")
let importing = CommandLine.arguments.contains("--import")
let context = LAContext()
context.interactionNotAllowed = !interactive

func read(_ service: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
}
func save(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = object["claudeAiOauth"] as? [String: Any], oauth["accessToken"] is String else { return false }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: cacheService, kSecAttrAccount as String: "current"]
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var item = query
    item[kSecValueData as String] = data
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
}
if importing {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    exit(save(data) ? 0 : 1)
}
if interactive {
    guard let data = read("Claude Code-credentials"), save(data) else { exit(1) }
    exit(0)
}
// Read the current CLI credential when allowed, otherwise the app-owned cache.
// No original credentials are modified and background access may never prompt.
guard let data = read("Claude Code-credentials") ?? read(cacheService) else { exit(1) }
FileHandle.standardOutput.write(data)
