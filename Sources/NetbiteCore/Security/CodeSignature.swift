import Foundation
import Security

/// How much a code signature vouches for a file, from most to least trusted.
public enum TrustLevel: String, Codable, CaseIterable, Sendable {
    /// Signed by Apple as part of the system (`anchor apple`).
    case apple
    /// Distributed through the Mac App Store.
    case appStore
    /// Developer ID signed and notarized by Apple.
    case developerIDNotarized
    /// Developer ID signed but with no notarization ticket known to this Mac.
    case developerID
    /// Valid signature from a certificate that is none of the above, such as an Apple Development
    /// certificate or a self-made one. Gatekeeper would not let it run if downloaded.
    case otherCertificate
    /// Signed without an identity (`codesign -s -`, or linker-signed): proves integrity, not origin.
    case adHoc
    /// No code signature at all.
    case unsigned
    /// A signature is present but does not match the contents: the file was modified after signing.
    case invalid

    /// A short human description, suitable for a table cell.
    public var label: String {
        switch self {
        case .apple: "Apple (system)"
        case .appStore: "Mac App Store"
        case .developerIDNotarized: "Developer ID, notarized"
        case .developerID: "Developer ID, not notarized"
        case .otherCertificate: "Signed (non-distribution certificate)"
        case .adHoc: "Ad-hoc signed"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid signature"
        }
    }
}

/// What the code signature of a file or bundle says about it.
public struct CodeSignatureInfo: Codable, Hashable, Sendable {
    public var path: String
    public var trustLevel: TrustLevel
    public var isSigned: Bool
    /// `false` when signed but the signature does not verify; see `validationError`.
    public var isValid: Bool
    /// Security framework message for a broken signature.
    public var validationError: String?
    public var isAdHoc: Bool
    /// Satisfies `anchor apple`: shipped by Apple.
    public var isApplePlatform: Bool
    public var isAppStore: Bool
    public var isDeveloperID: Bool
    /// Satisfies the `notarized` requirement: a notarization ticket is stapled or known to this Mac.
    public var isNotarized: Bool
    /// Hardened runtime flag (`codesign -o runtime`).
    public var hasHardenedRuntime: Bool
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    /// Common name of the leaf certificate, e.g. "Developer ID Application: Example (ABCDE12345)".
    public var signerName: String?
    /// The executable the signature covers (inside the bundle for an app).
    public var mainExecutable: String?
    /// Number of top-level entitlement keys, `nil` when the signature carries none.
    public var entitlementCount: Int?
}

/// Static code signature analysis with Security.framework. The file is only read, never run.
public enum CodeSignature {
    public enum AnalysisError: Error, CustomStringConvertible {
        case notFound(String)
        case unsupported(String, OSStatus)

        public var description: String {
            switch self {
            case .notFound(let path): "No such file: \(path)"
            case .unsupported(let path, let status): "Cannot read the code signature of \(path): \(CodeSignature.message(for: status))"
            }
        }
    }

    // Designated requirements in the language of `codesign -R` / csreq(1).
    static let appleRequirement = "anchor apple"
    /// Leaf issued by Apple for Mac App Store submissions (OID 1.2.840.113635.100.6.1.9).
    static let appStoreRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    /// The Developer ID intermediate (6.2.6) and a Developer ID Application leaf (6.1.13),
    /// the same check `spctl` uses for downloaded apps.
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    static let notarizedRequirement = "notarized"

    // SecCodeSignatureFlags bits from <Security/CSCommon.h>.
    private static let adHocFlag: UInt32 = 0x0002
    private static let runtimeFlag: UInt32 = 0x0001_0000
    private static let linkerSignedFlag: UInt32 = 0x0002_0000

    /// Analyzes the signature of a file or bundle at `url`.
    ///
    /// Nested code inside a bundle is not deep-verified: on large apps (Xcode, Office) that takes
    /// minutes. The main executable and the bundle's sealed resources are.
    public static func analyze(_ url: URL) throws -> CodeSignatureInfo {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { throw AnalysisError.notFound(path) }

        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else { throw AnalysisError.unsupported(path, created) }

        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validity = SecStaticCodeCheckValidity(code, checkFlags, nil)
        let isSigned = validity != errSecCSUnsigned
        let isValid = validity == errSecSuccess

        var info = CodeSignatureInfo(
            path: path, trustLevel: .unsigned, isSigned: isSigned, isValid: isValid,
            validationError: isSigned && !isValid ? message(for: validity) : nil,
            isAdHoc: false, isApplePlatform: false, isAppStore: false, isDeveloperID: false,
            isNotarized: false, hasHardenedRuntime: false
        )

        var rawInfo: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        if SecCodeCopySigningInformation(code, infoFlags, &rawInfo) == errSecSuccess,
           let dict = rawInfo as? [String: Any] {
            info.mainExecutable = (dict[kSecCodeInfoMainExecutable as String] as? URL)?.path
            if isSigned {
                let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
                info.isAdHoc = flags & (adHocFlag | linkerSignedFlag) != 0
                info.hasHardenedRuntime = flags & runtimeFlag != 0
                info.signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String
                info.teamIdentifier = dict[kSecCodeInfoTeamIdentifier as String] as? String
                info.entitlementCount = (dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.count
                if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
                   let leaf = certificates.first {
                    info.signerName = SecCertificateCopySubjectSummary(leaf) as String?
                }
            }
        }

        // Requirements only mean something on a signature that verifies.
        if isValid && !info.isAdHoc {
            info.isApplePlatform = satisfies(code, appleRequirement)
            info.isAppStore = !info.isApplePlatform && satisfies(code, appStoreRequirement)
            info.isDeveloperID = !info.isApplePlatform && satisfies(code, developerIDRequirement)
            info.isNotarized = info.isDeveloperID && satisfies(code, notarizedRequirement)
        }
        info.trustLevel = trustLevel(of: info)
        return info
    }

    static func trustLevel(of info: CodeSignatureInfo) -> TrustLevel {
        if !info.isSigned { return .unsigned }
        if !info.isValid { return .invalid }
        if info.isAdHoc { return .adHoc }
        if info.isApplePlatform { return .apple }
        if info.isAppStore { return .appStore }
        if info.isDeveloperID { return info.isNotarized ? .developerIDNotarized : .developerID }
        return .otherCertificate
    }

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text) (\(status))"
    }
}
