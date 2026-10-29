import Foundation
import CoreLocation

struct Profile: Codable, Equatable {
    var id: String
    var handle: String
    var is_admin: Bool?
    var created_at: Date?
    var invited_by: String?
}

struct InviteRow: Codable, Identifiable, Hashable {
    var code: String
    var used_by_handle: String?
    var used_at: Date?
    var id: String { code }
}

struct WallDTO: Codable, Identifiable, Equatable {
    var id: String
    var lat: Double
    var lng: Double
    var alt: Double
    var qx: Float, qy: Float, qz: Float, qw: Float
    var heading: Float
    var canvas_x0: Float
    var canvas_y0: Float
    var canvas_w: Float
    var canvas_h: Float
    var last_painted_at: Date?
    var dist: Double?
    var piece_count: Int?
    var anchors: [String]?
}

struct MapWall: Codable, Identifiable, Equatable {
    var id: String
    var lat: Double
    var lng: Double
    var heading: Float?
    var last_painted_at: Date?
    var piece_count: Int
    var last_artist: String?
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct PieceDTO: Codable, Identifiable, Equatable {
    var id: String
    var wall_id: String
    var kind: String
    var data: PieceData
    var x0: Float, y0: Float, x1: Float, y1: Float
    var props_count: Int
    var comment_count: Int
    var created_at: Date
    var author_id: String?
    var handle: String?
    var i_propped: Bool?
    var mine: Bool?
    // only in my_pieces
    var hidden: Bool?
    var archived: Bool?
    var lat: Double?
    var lng: Double?
}

struct CommentDTO: Codable, Identifiable, Equatable {
    var id: String
    var body: String
    var created_at: Date
    var author_id: String
    var handle: String
    var mine: Bool
}

struct ActivityItem: Codable, Identifiable, Equatable {
    var kind: String          // prop | comment | over | joined
    var at: Date
    var handle: String
    var piece_id: String?
    var wall_id: String?
    var body: String?
    var id: String { "\(kind)-\(handle)-\(at.timeIntervalSince1970)-\(piece_id ?? "")" }
}

struct ProfileCard: Codable, Equatable {
    var id: String
    var handle: String
    var since: Date
    var pieces: Int
    var walls: Int
    var props: Int
    var invited_by: String?
    var crew: [String]
    var blocked: Bool
}

struct BlockedUser: Codable, Identifiable, Equatable {
    var id: String
    var handle: String
    var created_at: Date
}

struct CreatedWall: Codable { var id: String; var existing: Bool }
struct CreatedPiece: Codable { var id: String; var created_at: Date }
