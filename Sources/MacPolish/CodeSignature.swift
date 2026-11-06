import Foundation
import Security

/// Who signed a program or app, as macOS's code signing checks see it. Read-only: nothing is re-signed or changed.
struct CodeSignatureSummary: Codable, Sendable, Hashable {
    enum Trust: String, Codable, Sendable {
        /// Signed by Apple itself (`anchor apple`): macOS and Apple's own tools.
        case apple
        /// Signed by the Mac App Store.
        case appStore
        /// Signed by a registered developer with a Developer ID certificate.
        case developerID
        /// A valid signature from another certificate, for example Apple Development or a self-made identity.
        case otherSigned
        /// Signed without an identity (`codesign -s -`): proves nothing about who made it.
        case adHoc
        case unsigned
        /// A signature that no longer matches the code, or a malformed one.
        case invalid
        /// Nothing exists at the path.
        case missing
        /// The signature could not be read.
        case unknown
    }

    var trust: Trust
    var teamID: String?
    var signingID: String?
    /// The Security framework status when the signature was rejected; nil otherwise.
    var status: Int32? = nil

    /// Short badge text, for example "Developer ID · 9BNSXJN65R".
    var label: String {
        switch trust {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerID: teamID.map { "Developer ID · \($0)" } ?? "Developer ID"
        case .otherSigned: teamID.map { "Signed · \($0)" } ?? "Signed (other certificate)"
        case .adHoc: "Ad-hoc signed"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid signature"
        case .missing: "Missing"
        case .unknown: "Signature unknown"
        }
    }

    /// True for signatures that identify a developer macOS trusts.
    var isTrustedIdentity: Bool { [.apple, .appStore, .developerID].contains(trust) }
}

enum CodeSignatureInspector {
    /// Requirement strings from Apple's code signing documentation (TN3127 and `csreq`).
    static let appleRequirement = "anchor apple"
    static let appStoreRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    /// Checks the signature of the file or bundle at `url`.
    ///
    /// Every architecture slice of the executable is validated (`kSecCSCheckAllArchitectures`). Bundle
    /// resources are not, unless `validateResources` is true: validating them reads every file in the
    /// bundle, which takes many seconds for large apps such as Xcode. A modified resource inside an app
    /// therefore still reports the executable's signature; Gatekeeper checks resources when the app opens.
    static func inspect(_ url: URL, validateResources: Bool = false) -> CodeSignatureSummary {
        guard FileManager.default.fileExists(atPath: url.path) else { return CodeSignatureSummary(trust: .missing) }
        var created: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &created)
        guard status == errSecSuccess, let code = created else { return summary(forFailure: status) }

        var rawFlags = UInt32(kSecCSCheckAllArchitectures)
        if !validateResources { rawFlags |= UInt32(kSecCSDoNotValidateResources) }
        let flags = SecCSFlags(rawValue: rawFlags)
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        guard validity == errSecSuccess else { return summary(forFailure: validity) }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information)
        let info = infoStatus == errSecSuccess ? (information as? [String: Any] ?? [:]) : [:]
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String
        let signatureFlags = SecCodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        if signatureFlags.contains(.adhoc) {
            return CodeSignatureSummary(trust: .adHoc, teamID: nil, signingID: signingID)
        }
        // The signature is valid; the requirements only decide which kind of certificate made it.
        let trust: CodeSignatureSummary.Trust
        if satisfies(code, appleRequirement, flags) {
            trust = .apple
        } else if satisfies(code, appStoreRequirement, flags) {
            trust = .appStore
        } else if satisfies(code, developerIDRequirement, flags) {
            trust = .developerID
        } else {
            trust = .otherSigned
        }
        return CodeSignatureSummary(trust: trust, teamID: teamID, signingID: signingID)
    }

    /// Maps a Security framework status to a summary for code that could not be validated.
    static func summary(forFailure status: OSStatus) -> CodeSignatureSummary {
        switch status {
        case errSecCSUnsigned: CodeSignatureSummary(trust: .unsigned)
        case errSecCSStaticCodeNotFound: CodeSignatureSummary(trust: .missing)
        // A signature exists but does not hold: tampered code, broken seals, revoked or untrusted certificates.
        case errSecCSSignatureFailed, errSecCSSignatureInvalid, errSecCSSignatureNotVerifiable, errSecCSSignatureUnsupported,
             errSecCSSignatureUntrusted, errSecCSRevokedNotarization, errSecCSBadResource, errSecCSResourcesInvalid,
             errSecCSResourcesNotFound, errSecCSResourcesNotSealed, errSecCSBadMainExecutable, errSecCSInfoPlistFailed,
             errSecCSBadDictionaryFormat, errSecCSBadObjectFormat, errSecCSNoMainExecutable, errSecCSBadNestedCode,
             errSecCSUnsignedNestedCode, errSecCSUnsealedAppRoot, errSecCSUnsealedFrameworkRoot, errSecCSWeakResourceRules,
             errSecCSWeakResourceEnvelope, errSecCSReqFailed, errSecCSInvalidSymlink, errSecCSInvalidTeamIdentifier,
             errSecCSBadTeamIdentifier:
            CodeSignatureSummary(trust: .invalid, status: status)
        default:
            // Unreadable files and unexpected formats: say "unknown" instead of guessing.
            CodeSignatureSummary(trust: .unknown, status: status)
        }
    }

    /// App groups the code at `url` declares (`com.apple.security.application-groups`). The signature is not
    /// validated here: the result only keeps data in use from being reported as left over, never the reverse.
    static func applicationGroups(_ url: URL) -> [String] {
        var created: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &created) == errSecSuccess, let code = created else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: String, _ flags: SecCSFlags) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
        return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
    }
}
