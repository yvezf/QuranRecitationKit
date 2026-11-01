/// Arabic normalization used by the text-side  CTC pipeline.
///
/// This intentionally stays narrow and deterministic: it mirrors the MIT
/// upstream normalizer rather than applying presentation-form folding or broad
/// transliteration that could silently change matching behavior.
enum ArabicNormalizer {
    static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)

        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard !shouldRemove(value) else { continue }

            switch value {
            case 0x0623, 0x0625, 0x0622, 0x0671: // أ إ آ ٱ -> ا
                result.unicodeScalars.append("\u{0627}")
            case 0x0629: // ة -> ه
                result.unicodeScalars.append("\u{0647}")
            case 0x0649: // ى -> ي
                result.unicodeScalars.append("\u{064A}")
            default:
                result.unicodeScalars.append(scalar)
            }
        }

        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func shouldRemove(_ value: UInt32) -> Bool {
        switch value {
        case 0xFEFF, // byte-order mark
             0x0640, // tatweel
             0x0670: // superscript alef
            return true
        case 0x0610...0x061A,
             0x064B...0x065F,
             0x06D6...0x06DE,
             0x06DF...0x06ED:
            return true
        default:
            return false
        }
    }
}
