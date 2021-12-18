import Foundation

public extension GeoCoordinate {
    /// A range of valid latitude values (from -90 to 90 degrees)
    static var validLatitudeRange: ClosedRange<Double> { -90...90 }
    /// A range of valid longitude values (from -180 to 180 degrees)
    static var validLongitudeRange: ClosedRange<Double> { -180...180 }

    /// Calculates the distance in meters to another `GeoCoordinate`.
    /// - Parameter to: Destination coordinate (given latitude & longitude degrees) to which the distance should be calculated.
    /// - Returns: Distance in meters.
    func distance(to: GeoCoordinate) -> Double {
        return calculateHaversineDistance(to: to)
    }

    /// Performs a mercator projection of a geo coordinate to values in meters along x/y
    /// - Returns: A pair of x/y-values in meters.
    ///
    /// This produces a fast approximation to the truer, but heavier elliptical projection, where the Earth would be projected on a more accurate ellipsoid (flattened on poles). As a consequence, direct measurements of distances in this projection will be approximative, except on the Equator, and the aspect ratios on the rendered map for true squares measured on the surface on Earth will slightly change with latitude and angles not so precisely preserved by this spherical projection.
    /// [More details on Wikipedia](https://wiki.openstreetmap.org/wiki/Mercator)
    func mercatorProjectionToMeters() -> (x: Double, y: Double) {
        let earthRadius: Double = 6_378_137.0 // meters
        let yInMeters: Double = log(tan(.pi / 4.0 + latitude.degreesToRadians / 2.0)) * earthRadius
        let xInMeters: Double = longitude.degreesToRadians * earthRadius
        return (x: xInMeters, y: -yInMeters)
    }

    /// Performs a mercator projection of a geo coordinate to values in degrees
    /// - Returns: A pair of x/y-values in latitude/longitude degrees.
    ///
    /// This produces a fast approximation to the truer, but heavier elliptical projection, where the Earth would be projected on a more accurate ellipsoid (flattened on poles). As a consequence, direct measurements of distances in this projection will be approximative, except on the Equator, and the aspect ratios on the rendered map for true squares measured on the surface on Earth will slightly change with latitude and angles not so precisely preserved by this spherical projection.
    /// [More details on Wikipedia](https://wiki.openstreetmap.org/wiki/Mercator)
    func mercatorProjectionToDegrees() -> (x: Double, y: Double) {
        return (x: longitude, y: -log(tan(latitude.degreesToRadians / 2 + .pi / 4)).radiansToDegrees)
    }
}

extension TrackPoint: GeoCoordinate {
    public var latitude: Double { coordinate.latitude }
    public var longitude: Double { coordinate.longitude }
}

public extension TrackGraph {
    /// Convenience initialize for creating a `TrackGraph`  from `Coordinate`s.
    /// - Parameter coords: Array of `Coordinate` values.
    /// - Parameter gradeSegmentLength: The Length of the grade segments in meters. Defaults to 25.
    init(coords: [Coordinate], gradeSegmentLength: Double = 25) {
        let zippedCoords = zip(coords, coords.dropFirst())
        let distances: [Double] = [0.0] + zippedCoords.map {
            $0.distance(to: $1)
        }
        segments = zip(coords, distances).map {
            TrackSegment(coordinate: $0, distanceInMeters: $1)
        }
        distance = distances.reduce(0, +)
        elevationGain = zippedCoords.reduce(0.0) { elevation, pair in
            let delta = pair.1.elevation - pair.0.elevation
            if delta > 0 {
                return elevation + delta
            }
            return elevation
        }
        let heightmap = segments.reduce(into: [DistanceHeight]()) { acc, segment in
            let distanceSoFar = (acc.last?.distance ?? 0) + segment.distanceInMeters
            acc.append(DistanceHeight(distance: distanceSoFar, elevation: segment.coordinate.elevation))
        }
        self.heightMap = heightmap
        self.gradeSegments = heightmap.calculateGradeSegments(segmentLength: gradeSegmentLength)
    }
}

private extension Array where Element == DistanceHeight {
    func calculateGradeSegments(segmentLength: Double) -> [GradeSegment] {
        guard !isEmpty else { return [] }

        let trackDistance = self[endIndex - 1].distance
        guard trackDistance >= segmentLength else {
            if let prevHeight = height(at: 0), let currentHeight = height(at: trackDistance) {
                return [.init(start: 0, end: trackDistance, grade: (currentHeight - prevHeight) / trackDistance)]
            }
            return []
        }
        var gradeSegments: [GradeSegment] = []
        var previousHeight: Double = self[0].elevation
        for distance in stride(from: segmentLength, to: trackDistance, by: segmentLength) {
            guard let height = height(at: distance) else { break }
            gradeSegments.append(.init(start: distance - segmentLength, end: distance, grade: (height - previousHeight) / segmentLength))
            previousHeight = height
        }
        if let last = gradeSegments.last,
           last.end < trackDistance {
            if let prevHeight = height(at: last.end), let currentHeight = height(at: trackDistance) {
                gradeSegments.append(.init(start: last.end, end: trackDistance, grade: (currentHeight - prevHeight) / (trackDistance - last.end)))
            }
        }
        return gradeSegments.reduce(into: []) { joined, segment in
            guard let last = joined.last else {
                joined.append(segment)
                return
            }
            if abs(last.grade - segment.grade) > 0.01 {
                joined.append(segment)
            } else {
                let remaining = Swift.min(segmentLength, trackDistance - last.end)
                joined[joined.count - 1].end += remaining
            }
        }
    }

    func height(at distance: Double) -> Double? {
        if distance == 0 {
            return first?.elevation
        }
        if distance == last?.distance {
            return last?.elevation
        }
        guard let next = firstIndex(where: { element in
            element.distance > distance
        }), next > 0 else { return nil }

        let start = next - 1
        let delta = self[next].distance - self[start].distance
        let t = (distance - self[start].distance) / delta
        return linearInterpolated(start: self[start].elevation, end: self[next].elevation, using: t)
    }

    func linearInterpolated<Value: FloatingPoint>(start: Value, end: Value, using t: Value) -> Value {
        start + t * (end - start)
    }
}

public extension TrackGraph {
    /// Calculates the `TrackGraph`s climbs.
    /// - Parameters:
    ///   - epsilon: The simplification factor in meters for smoothing out elevation jumps. Defaults to 1.
    ///   - minimumGrade: The minimum allowed grade in percent in the Range {0,1}. Defaults to 0.03 (3%).
    ///   - maxJoinDistance:The maximum allowed distance between climb segments in meters. If Climb segments are closer they will get joined to one climb. Defaults to 0.
    /// - Returns: An array of `Climb` values. Returns an empty array if no climbs where found.
    func climbs(epsilon: Double = 1, minimumGrade: Double = 0.03, maxJoinDistance: Double = 0) -> [Climb] {
        guard
            heightMap.count > 1
        else {
            return []
        }
        return findClimps(epsilon: epsilon, minimumGrade: minimumGrade, maxJoinDistance: maxJoinDistance)
    }
}

public extension GPXFileParser {
    /// Convenience initialize for loading a GPX file from an url. Fails if the track cannot be parsed.
    /// - Parameter url: The url containing the GPX file. See [GPX specification for details](https://www.topografix.com/gpx.asp).
    /// - Returns: An `GPXFileParser` instance or nil if the track cannot be parsed.
    convenience init?(url: URL) {
        guard let xmlString = try? String(contentsOf: url) else { return nil }
        self.init(xmlString: xmlString)
    }

    /// Convenience initialize for loading a GPX file from a data. Returns nil if the track cannot be parsed.
    /// - Parameter data: Data containing the GPX file as encoded xml string. See [GPX specification for details](https://www.topografix.com/gpx.asp).
    /// - Returns: An `GPXFileParser` instance or nil if the track cannot be parsed.
    convenience init?(data: Data) {
        guard let xmlString = String(data: data, encoding: .utf8) else { return nil }
        self.init(xmlString: xmlString)
    }
}

public extension GeoBounds {
    /// The _zero_ value of GeoBounds.
    ///
    /// Its values are not zero but contain the following values:
    /// ### minLatitude
    /// `Coordinate.validLatitudeRange.upperBound`
    /// ### minLongitude
    /// `Coordinate.validLongitudeRange.upperBound`
    /// ### maxLatitude
    /// `Coordinate.validLatitudeRange.lowerBound`
    /// #### maxLongitude
    /// `Coordinate.validLongitudeRange.lowerBound`
    ///
    /// See `Coordinate.validLongitudeRange` & `Coordinate.validLatitudeRange.upperBound` for details.
    static let empty = GeoBounds(
        minLatitude: Coordinate.validLatitudeRange.upperBound,
        minLongitude: Coordinate.validLongitudeRange.upperBound,
        maxLatitude: Coordinate.validLatitudeRange.lowerBound,
        maxLongitude: Coordinate.validLongitudeRange.lowerBound
    )

    /// Tests if two `GeoBound` values intersects
    /// - Parameter rhs: The other `GeoBound` to test for intersection.
    /// - Returns: True if both bounds intersect, otherwise false.
    func intersects(_ rhs: GeoBounds) -> Bool {
        return (minLatitude...maxLatitude).overlaps(rhs.minLatitude...rhs.maxLatitude) &&
            (minLongitude...maxLongitude).overlaps(rhs.minLongitude...rhs.maxLongitude)
    }

    /// Tests if a `GeoCoordinate` is within a `GeoBound`
    /// - Parameter coordinate: The `GeoCoordinate` to test for.
    /// - Returns: True if coordinate is within the bounds otherwise false.
    func contains(_ coordinate: GeoCoordinate) -> Bool {
        return (minLatitude...maxLatitude).contains(coordinate.latitude) &&
            (minLongitude...maxLongitude).contains(coordinate.longitude)
    }
}

public extension Collection where Element: GeoCoordinate {
    /// Creates a bounding box from a collection of `GeoCoordinate`s.
    /// - Returns: The 2D representation of the bounding box as `GeoBounds` value.
    func bounds() -> GeoBounds {
        reduce(GeoBounds.empty) { bounds, coord in
            GeoBounds(
                minLatitude: Swift.min(bounds.minLatitude, coord.latitude),
                minLongitude: Swift.min(bounds.minLongitude, coord.longitude),
                maxLatitude: Swift.max(bounds.maxLatitude, coord.latitude),
                maxLongitude: Swift.max(bounds.maxLongitude, coord.longitude)
            )
        }
    }
}

public extension GeoCoordinate {
    /// Helper method for offsetting a `GeoCoordinate`. Useful in tests or for tweaking a known location
    /// - Parameters:
    ///   - north: The offset in meters in _vertical_ direction as seen on a map. Use negative values to go _upwards_ on a globe, positive values for moving downwards.
    ///   - east: The offset in meters in _horizontal_ direction as seen on a map. Use negative values to go to the _west_ on a globe, positive values for moving in the _eastern_ direction.
    /// - Returns: A new `Coordinate` value, offset by north and east values in meters.
    ///
    /// ```swift
    /// let position = Coordinate(latitude: 51.323331, longitude: 12.368279)
    /// position.offset(east: 60),
    /// position.offset(east: -100),
    /// position.offset(north: 120),
    /// position.offset(north: -160),
    /// ```
    /// 
    /// See [here](https://gis.stackexchange.com/questions/2951/algorithm-for-offsetting-a-latitude-longitude-by-some-amount-of-meters) for more details.
    func offset(north: Double = 0, east: Double = 0) -> Coordinate {
        // Earth’s radius, sphere
        let radius: Double = 6_378_137

        // Coordinate offsets in radians
        let dLat = north / radius
        let dLon = east / (radius * cos(.pi * latitude / 180))

        // OffsetPosition, decimal degrees
        return Coordinate(
            latitude: latitude + dLat * 180 / .pi,
            longitude: longitude + dLon * 180 / .pi
        )
    }
}

public extension GeoCoordinate {

    /// Calculates the bearing of the coordinate to a second
    /// - Parameter target: The second coordinate
    /// - Returns: The bearing to `target`in degrees
    func bearing(target: Coordinate) -> Double {
        let lat1 = latitude.degreesToRadians
        let lon1 = longitude.degreesToRadians
        let lat2 = target.latitude.degreesToRadians
        let lon2 = target.longitude.degreesToRadians

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)

        return radiansBearing.radiansToDegrees
    }
}
