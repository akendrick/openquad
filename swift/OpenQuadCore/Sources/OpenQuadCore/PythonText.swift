// Python's repr() of str and bytes, so error messages read the same in both versions.

/// repr(s) for a str.
func pyRepr(_ s: String) -> String {
    let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for c in s.unicodeScalars {
        switch c {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where Character(c) == quote: out += "\\\(quote)"
        case _ where c.value < 0x20 || c.value == 0x7f: out += String(format: "\\x%02x", c.value)
        default: out.unicodeScalars.append(c)
        }
    }
    return out + String(quote)
}

/// repr(b) for bytes.
func pyRepr(_ bytes: [UInt8]) -> String {
    let quote: UInt8 = bytes.contains(0x27) && !bytes.contains(0x22) ? 0x22 : 0x27
    var out = "b" + String(UnicodeScalar(quote))
    for b in bytes {
        switch b {
        case 0x5c: out += "\\\\"
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        case quote: out += "\\" + String(UnicodeScalar(quote))
        case 0x20..<0x7f: out += String(UnicodeScalar(b))
        default: out += String(format: "\\x%02x", b)
        }
    }
    return out + String(UnicodeScalar(quote))
}
