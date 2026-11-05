import Foundation
import Security
import LocalAuthentication

let selfTest = CommandLine.arguments.contains("--self-test")
let cacheService = "dev.bambam.QuotaGarden.ClaudeSession" + (selfTest ? ".SelfTest" : "")
let interactive = CommandLine.arguments.contains("--connect")
let importing = CommandLine.arguments.contains("--import")
// LAContext does not reliably suppress legacy login-keychain ACL dialogs.
// Disable legacy Keychain UI process-wide unless the user explicitly connects.
if !interactive { SecKeychainSetUserInteractionAllowed(false) }
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
    // Updating data preserves the old binary's decrypt ACL after a rebuild.
    // Recreate only our cache after an explicit connection/import, with this reader's ACL.
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { return false }
    var item = query
    item[kSecValueData as String] = data
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
    return true
}
if selfTest {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"self-test-not-a-credential"}}"#.utf8)
    guard save(data), read(cacheService) == data else { exit(1) }
    // Prove a separate background process can read the new item's decrypt ACL.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    probe.arguments = ["--self-test-read"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do { try probe.run(); probe.waitUntilExit() } catch { exit(1) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: cacheService, kSecAttrAccount as String: "current"]
    SecItemDelete(query as CFDictionary)
    exit(probe.terminationStatus)
}
if CommandLine.arguments.contains("--self-test-read") {
    exit(read("dev.bambam.QuotaGarden.ClaudeSession.SelfTest") == nil ? 1 : 0)
}
if importing {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    exit(save(data) ? 0 : 1)
}
if interactive {
    guard let data = read("Claude Code-credentials"), save(data) else { exit(1) }
    // A successful write alone does not mean background reads are authorized.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do { try probe.run(); probe.waitUntilExit(); exit(probe.terminationStatus) } catch { exit(1) }
}
// Poll only our own cache. Access to Claude's item requires an explicit --connect.
guard let data = read(cacheService) else { exit(1) }
FileHandle.standardOutput.write(data)
