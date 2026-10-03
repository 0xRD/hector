import Foundation

/// Text that came from a client or the network, made safe for a single log line.
public enum LogText {
    public static let maximumLength = 2_000

    /// Control characters (newlines included) are escaped, so a client cannot forge log lines,
    /// and long messages are cut.
    public static func sanitized(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if result.unicodeScalars.count >= maximumLength {
                result += "…"
                break
            }
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
