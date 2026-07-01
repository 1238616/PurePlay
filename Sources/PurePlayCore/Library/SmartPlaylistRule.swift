import Foundation

/// Smart playlist rule definition
public struct SmartPlaylistRule: Codable {
    public enum Field: String, CaseIterable, Codable {
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        case genre = "Genre"
        case year = "Year"
        case duration = "Duration"
        case playCount = "Play Count"
    }
    
    public enum Operator: String, CaseIterable, Codable {
        case contains = "contains"
        case doesNotContain = "does not contain"
        case equals = "is"
        case notEquals = "is not"
        case greaterThan = "is greater than"
        case lessThan = "is less than"
    }
    
    public var field: Field
    public var op: Operator
    public var value: String
    
    public init(field: Field, op: Operator, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }
}
