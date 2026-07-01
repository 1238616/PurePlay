import Foundation

public struct EQPreset: Codable, Sendable {
    public var name: String
    public var description: String
    public var preamp: Float
    public var bands: [ParametricBand]

    public init(name: String, description: String = "", preamp: Float = 0, bands: [ParametricBand] = []) {
        self.name = name
        self.description = description
        self.preamp = preamp
        self.bands = bands
    }

    public static let flat = EQPreset(name: "Flat", description: "No EQ applied")
}

public final class EQPresetManager {

    public static let shared = EQPresetManager()

    private let userPresetsDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        userPresetsDirectory = appSupport.appendingPathComponent("PurePlay/EQPresets", isDirectory: true)
    }

    // MARK: - Factory Presets

    public func loadFactoryPresets() -> [EQPreset] {
        guard let url = findFactoryPresetsURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let presetsArray = json["presets"] as? [[String: Any]] else {
            return [.flat]
        }

        let frequencies = ParametricEQNode.graphicFrequencies
        return presetsArray.compactMap { dict -> EQPreset? in
            guard let name = dict["name"] as? String else { return nil }
            let description = dict["description"] as? String ?? ""
            let preamp = (dict["preamp"] as? NSNumber).map { Float(truncating: $0) } ?? 0

            if let parametric = dict["parametric"] as? [[String: Any]] {
                let bands = parametric.compactMap { parseBandDict($0) }
                return EQPreset(name: name, description: description, preamp: preamp, bands: bands)
            }

            if let gains = dict["gains"] as? [NSNumber] {
                let bands = zip(frequencies, gains).map { freq, gain in
                    ParametricBand(type: .peaking, frequency: freq, gain: Float(truncating: gain), q: 1.414)
                }
                return EQPreset(name: name, description: description, preamp: preamp, bands: bands)
            }

            return EQPreset(name: name, description: description, preamp: preamp)
        }
    }

    // MARK: - User Presets

    public func loadUserPresets() -> [EQPreset] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: userPresetsDirectory,
                                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(EQPreset.self, from: data)
            }
    }

    public func saveUserPreset(_ preset: EQPreset) throws {
        ensureDirectory()
        let safeName = preset.name.replacingOccurrences(of: "/", with: "_")
        let url = userPresetsDirectory.appendingPathComponent("\(safeName).json")
        let data = try JSONEncoder().encode(preset)
        try data.write(to: url, options: .atomic)
    }

    public func deleteUserPreset(name: String) throws {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let url = userPresetsDirectory.appendingPathComponent("\(safeName).json")
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Import

    public func importAutoEQ(from url: URL) throws -> EQPreset {
        let result = try AutoEQParser.parse(file: url)
        let name = url.deletingPathExtension().lastPathComponent
        if let headphone = result.headphoneName {
            AudioPreferences.currentHeadphoneName = headphone
        }
        return EQPreset(name: name, preamp: result.preamp, bands: result.bands)
    }

    public func importJSON(from url: URL) throws -> EQPreset {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EQPreset.self, from: data)
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: userPresetsDirectory,
                                                  withIntermediateDirectories: true)
    }

    private func findFactoryPresetsURL() -> URL? {
        if let url = Bundle.main.url(forResource: "EQPresets", withExtension: "json") {
            return url
        }
        let fallback = URL(fileURLWithPath: "Resources/EQPresets.json")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    private func parseBandDict(_ dict: [String: Any]) -> ParametricBand? {
        guard let typeStr = dict["type"] as? String,
              let type = FilterType(rawValue: typeStr),
              let freq = dict["freq"] as? Double,
              let gain = (dict["gain"] as? NSNumber).map({ Float(truncating: $0) }),
              let q = dict["q"] as? Double else {
            return nil
        }
        let enabled = dict["enabled"] as? Bool ?? true
        return ParametricBand(type: type, frequency: freq, gain: gain, q: q, enabled: enabled)
    }
}
