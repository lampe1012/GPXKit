import Foundation

public protocol GeoCoordinate {
    var latitude: Double { get}
    var longitude: Double { get }
}

public struct Coordinate: Equatable, Hashable, GeoCoordinate {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double
}

public struct TrackSegment: Hashable {
    public var coordinate: Coordinate
    public var distanceInMeters: Double
}

public struct TrackPoint: Hashable {
    public var coordinate: Coordinate
    public var date: Date?
    public var power: Measurement<UnitPower>?
}

public struct TrackGraph: Equatable {
    public var segments: [TrackSegment]
    public var distance: Double
    public var elevationGain: Double
    public var heightMap: [DistanceHeight]
}

public struct DistanceHeight: Hashable {
    public var distance: Double
    public var elevation: Double

    public init(distance: Double, elevation: Double) {
        self.distance = distance
        self.elevation = elevation
    }
}

public struct GPXTrack: Equatable {
    public var date: Date?
    public var title: String
    public var trackPoints: [TrackPoint]
    public var graph: TrackGraph

    public init(date: Date? = nil, title: String, trackPoints: [TrackPoint]) {
        self.date = date
        self.title = title
        self.trackPoints = trackPoints
        self.graph = TrackGraph(points: trackPoints)
    }
}