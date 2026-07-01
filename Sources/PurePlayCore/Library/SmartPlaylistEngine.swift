import Foundation

/// Smart playlist rules engine
/// Evaluates rules against tracks to determine matches
public final class SmartPlaylistEngine {
    
    /// Evaluate a set of rules against a collection of tracks
    /// - Parameters:
    ///   - rules: Array of SmartPlaylistRule to evaluate
    ///   - tracks: Array of TrackRecord to filter
    /// - Returns: Array of TrackRecord that match all rules
    public static func evaluate(rules: [SmartPlaylistRule], tracks: [TrackRecord]) -> [TrackRecord] {
        guard !rules.isEmpty else { return tracks }
        
        return tracks.filter { track in
            rules.allSatisfy { rule in
                evaluateRule(rule, against: track)
            }
        }
    }
    
    /// Evaluate a single rule against a track
    /// - Parameters:
    ///   - rule: SmartPlaylistRule to evaluate
    ///   - track: TrackRecord to test
    /// - Returns: true if the track matches the rule
    private static func evaluateRule(_ rule: SmartPlaylistRule, against track: TrackRecord) -> Bool {
        switch rule.field {
        case .title:
            return evaluateStringRule(operator: rule.op, value: rule.value, fieldValue: track.title)
        case .artist:
            return evaluateStringRule(operator: rule.op, value: rule.value, fieldValue: track.artist)
        case .album:
            return evaluateStringRule(operator: rule.op, value: rule.value, fieldValue: track.album)
        case .genre:
            return evaluateStringRule(operator: rule.op, value: rule.value, fieldValue: track.genre)
        case .year:
            guard let year = track.year else { return false }
            guard let ruleValue = Int(rule.value) else { return false }
            return evaluateNumericRule(operator: rule.op, value: ruleValue, fieldValue: year)
        case .duration:
            guard let ruleValue = Double(rule.value) else { return false }
            return evaluateNumericRule(operator: rule.op, value: ruleValue, fieldValue: track.duration)
        case .playCount:
            guard let ruleValue = Int(rule.value) else { return false }
            return evaluateNumericRule(operator: rule.op, value: ruleValue, fieldValue: track.playCount)
        }
    }
    
    /// Evaluate a string-based rule
    private static func evaluateStringRule(operator op: SmartPlaylistRule.Operator, value: String, fieldValue: String) -> Bool {
        let lowerValue = value.lowercased()
        let lowerFieldValue = fieldValue.lowercased()
        
        switch op {
        case .contains:
            return lowerFieldValue.contains(lowerValue)
        case .doesNotContain:
            return !lowerFieldValue.contains(lowerValue)
        case .equals:
            return lowerFieldValue == lowerValue
        case .notEquals:
            return lowerFieldValue != lowerValue
        case .greaterThan:
            return lowerFieldValue > lowerValue
        case .lessThan:
            return lowerFieldValue < lowerValue
        }
    }
    
    /// Evaluate a numeric-based rule
    private static func evaluateNumericRule<T: Comparable>(operator op: SmartPlaylistRule.Operator, value: T, fieldValue: T) -> Bool {
        switch op {
        case .contains:
            return false  // contains doesn't make sense for numbers
        case .doesNotContain:
            return true   // doesNotContain doesn't make sense for numbers
        case .equals:
            return fieldValue == value
        case .notEquals:
            return fieldValue != value
        case .greaterThan:
            return fieldValue > value
        case .lessThan:
            return fieldValue < value
        }
    }
    
    /// Parse JSON-encoded rules from database
    /// - Parameter json: JSON string containing array of rules
    /// - Returns: Array of SmartPlaylistRule, or empty array if parsing fails
    public static func parseRules(from json: String?) -> [SmartPlaylistRule] {
        guard let json = json,
              let data = json.data(using: .utf8) else {
            return []
        }
        
        do {
            return try JSONDecoder().decode([SmartPlaylistRule].self, from: data)
        } catch {
            print("Failed to parse smart playlist rules: \(error)")
            return []
        }
    }
    
    /// Encode rules to JSON string for database storage
    /// - Parameter rules: Array of SmartPlaylistRule to encode
    /// - Returns: JSON string, or nil if encoding fails
    public static func encodeRules(_ rules: [SmartPlaylistRule]) -> String? {
        do {
            let data = try JSONEncoder().encode(rules)
            return String(data: data, encoding: .utf8)
        } catch {
            print("Failed to encode smart playlist rules: \(error)")
            return nil
        }
    }
    
    /// Create a smart playlist and populate it with matching tracks
    /// - Parameters:
    ///   - name: Name for the playlist
    ///   - rules: Array of SmartPlaylistRule to evaluate
    ///   - databaseManager: DatabaseManager instance to use
    /// - Returns: ID of the created playlist
    public static func createSmartPlaylist(name: String, rules: [SmartPlaylistRule], databaseManager: DatabaseManager) throws -> Int64 {
        // Create the playlist record
        let playlist = PlaylistRecord(
            name: name,
            isSmart: true,
            smartRules: encodeRules(rules),
            dateCreated: Date(),
            dateModified: Date()
        )
        
        let playlistId = try databaseManager.addPlaylist(playlist)
        
        // Get all tracks and evaluate rules
        let allTracks = try databaseManager.allTracks()
        let matchingTracks = evaluate(rules: rules, tracks: allTracks)
        
        // Add matching tracks to playlist
        for (index, track) in matchingTracks.enumerated() {
            if let trackId = track.id {
                try databaseManager.addTrackToPlaylist(playlistId: playlistId, trackId: trackId, position: index)
            }
        }
        
        return playlistId
    }
    
    /// Update a smart playlist by re-evaluating rules
    /// - Parameters:
    ///   - playlistId: ID of the playlist to update
    ///   - rules: Array of SmartPlaylistRule to evaluate
    ///   - databaseManager: DatabaseManager instance to use
    public static func updateSmartPlaylist(playlistId: Int64, rules: [SmartPlaylistRule], databaseManager: DatabaseManager) throws {
        // Remove all existing tracks from playlist
        let existingTracks = try databaseManager.playlistTracks(playlistId: playlistId)
        for track in existingTracks {
            if let trackId = track.id {
                try databaseManager.removeTrackFromPlaylist(playlistId: playlistId, trackId: trackId)
            }
        }
        
        // Get all tracks and evaluate rules
        let allTracks = try databaseManager.allTracks()
        let matchingTracks = evaluate(rules: rules, tracks: allTracks)
        
        // Add matching tracks to playlist
        for (index, track) in matchingTracks.enumerated() {
            if let trackId = track.id {
                try databaseManager.addTrackToPlaylist(playlistId: playlistId, trackId: trackId, position: index)
            }
        }
        
        // Update playlist modification date
        if var playlist = try databaseManager.playlist(byId: playlistId) {
            playlist.dateModified = Date()
            playlist.smartRules = encodeRules(rules)
            try databaseManager.updatePlaylist(playlist)
        }
    }
}
