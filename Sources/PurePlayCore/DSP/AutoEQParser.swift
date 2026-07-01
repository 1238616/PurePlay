import Foundation

public struct AutoEQResult {
    public let preamp: Float
    public let bands: [ParametricBand]
    public let headphoneName: String?

    public init(preamp: Float, bands: [ParametricBand], headphoneName: String? = nil) {
        self.preamp = preamp
        self.bands = bands
        self.headphoneName = headphoneName
    }
}

public enum AutoEQParser {

    public static func parse(_ text: String) throws -> AutoEQResult {
        var preamp: Float = 0
        var bands: [ParametricBand] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let p = parsePreamp(trimmed) {
                preamp = p
                continue
            }

            if let band = parseFilter(trimmed) {
                bands.append(band)
            }
        }

        guard !bands.isEmpty else {
            throw PurePlayError.decodeFailed("No valid filter lines found in AutoEQ text")
        }

        if bands.count > ParametricBand.maxBands {
            bands = Array(bands.prefix(ParametricBand.maxBands))
        }

        return AutoEQResult(preamp: preamp, bands: bands, headphoneName: nil)
    }

    /// Parse an AutoEQ ParametricEQ.txt file. The headphone name is extracted
    /// from the file's last path component by stripping known AutoEQ suffixes.
    public static func parse(file url: URL) throws -> AutoEQResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        let inner = try parse(text)
        let name = extractHeadphoneName(from: url.lastPathComponent)
        return AutoEQResult(preamp: inner.preamp, bands: inner.bands, headphoneName: name)
    }

    public static func parseJSON(_ data: Data) throws -> AutoEQResult {
        struct NativePreset: Decodable {
            let preamp: Float?
            let bands: [ParametricBand]
        }
        let preset = try JSONDecoder().decode(NativePreset.self, from: data)
        return AutoEQResult(preamp: preset.preamp ?? 0, bands: preset.bands, headphoneName: nil)
    }

    /// "Sennheiser HD 600 ParametricEQ.txt" → "Sennheiser HD 600"
    /// Falls back to filename-minus-extension if no known suffix matches.
    /// Returns nil for an empty result.
    public static func extractHeadphoneName(from filename: String) -> String? {
        // Strip extension.
        var name: String
        if let dot = filename.lastIndex(of: ".") {
            name = String(filename[..<dot])
        } else {
            name = filename
        }
        // Strip known AutoEQ suffixes.
        let suffixes = [" ParametricEQ", " GraphicEQ", " FixedBandEQ", " ParamEQ"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parsePreamp(_ line: String) -> Float? {
        let pattern = #"[Pp]reamp:\s*([-+]?\d+\.?\d*)\s*dB"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Float(line[range])
    }

    private static func parseFilter(_ line: String) -> ParametricBand? {
        let pattern = #"Filter\s+\d+:\s*ON\s+(PK|LSC|HSC|LS|HS)\s+Fc\s+(\d+\.?\d*)\s*Hz\s+Gain\s+([-+]?\d+\.?\d*)\s*dB\s+Q\s+(\d+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let typeRange = Range(match.range(at: 1), in: line),
              let freqRange = Range(match.range(at: 2), in: line),
              let gainRange = Range(match.range(at: 3), in: line),
              let qRange = Range(match.range(at: 4), in: line) else {
            return nil
        }

        let typeStr = String(line[typeRange])
        let filterType: FilterType
        switch typeStr {
        case "PK": filterType = .peaking
        case "LSC", "LS": filterType = .lowShelf
        case "HSC", "HS": filterType = .highShelf
        default: return nil
        }

        guard let freq = Double(line[freqRange]),
              let gain = Float(line[gainRange]),
              let q = Double(line[qRange]) else {
            return nil
        }

        return ParametricBand(type: filterType, frequency: freq, gain: gain, q: q)
    }
}
