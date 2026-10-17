import Foundation

struct SurveyPlace: Equatable {
    var latitude: Double
    var longitude: Double
    var accuracyMeters: Double
}

struct SurveyVertex: Equatable {
    var bearing: Double
    var feet: Double
}

struct SurveyDot: Equatable {
    var bearing: Double?
    var feet: Double

    var distanceLabel: String {
        feet < 1 ? "Within 1 ft" : "\(Int(feet.rounded())) ft"
    }

    var directionLabel: String {
        NearbyScan.directionLabel(bearing)
    }
}

struct RoomPicture: Equatable {
    var walls: [[SurveyVertex]]
    var furnishings: [[SurveyVertex]]
    var dot: SurveyDot?
    var lines: [String]
    var rangeFeet: Double

    static let empty = RoomPicture(walls: [], furnishings: [], dot: nil, lines: [], rangeFeet: NearbyScan.maxFeet)
}

/// Turns the depth grid, nearby devices, and the joined Wi-Fi network into one picture.
/// The far depth in each column is a wall. A clearly closer depth is a near surface.
/// One dot is the center of those surfaces and any device that has a direction.
enum RoomSurvey {
    /// Forward arc the depth grid covers, in radians. Up on the circle is the top of the phone.
    static let span = Double.pi / 3
    static let furnitureGapMeters = 0.4
    private static let feetPerMeter = 3.280839895

    static func columnBearing(_ column: Int, columns: Int) -> Double {
        guard columns > 0 else { return 0 }
        return ((Double(column) + 0.5) / Double(columns) - 0.5) * span
    }

    static func picture(
        cells: [DepthCell],
        columns: Int,
        rows: Int,
        sightings: [NearbySighting],
        wifiName: String?,
        rangeFeet: Double
    ) -> RoomPicture {
        let surfaces = surfaces(cells: cells, columns: columns, rows: rows, rangeFeet: rangeFeet)
        var positioned = surfaces.walls.flatMap { $0 } + surfaces.furnishings.flatMap { $0 }
        var lines: [String] = []
        if let label = spanLabel(surfaces.walls, title: "Wall") {
            lines.append(label)
        }
        if let label = spanLabel(surfaces.furnishings, title: "Near surface") {
            lines.append(label)
        }
        var nearestUnplaced: NearbySighting?
        for sighting in sightings where NearbyScan.withinLimit(sighting.distanceFeet, rangeFeet: rangeFeet) {
            lines.append("\(sighting.source.title) \(sighting.name) \(sighting.distanceLabel)")
            if let bearing = sighting.bearing {
                positioned.append(SurveyVertex(bearing: bearing, feet: sighting.distanceFeet))
            } else if nearestUnplaced == nil || sighting.distanceFeet < nearestUnplaced!.distanceFeet {
                nearestUnplaced = sighting
            }
        }
        if let wifiName, !wifiName.isEmpty {
            lines.append("Wi-Fi \(wifiName)")
        } else {
            lines.append("Wi-Fi reads the joined network")
        }
        let dot = centroid(positioned) ?? nearestUnplaced.map { SurveyDot(bearing: nil, feet: $0.distanceFeet) }
        return RoomPicture(
            walls: surfaces.walls,
            furnishings: surfaces.furnishings,
            dot: dot,
            lines: lines,
            rangeFeet: rangeFeet
        )
    }

    private static func surfaces(
        cells: [DepthCell],
        columns: Int,
        rows: Int,
        rangeFeet: Double
    ) -> (walls: [[SurveyVertex]], furnishings: [[SurveyVertex]]) {
        guard columns > 0, rows > 0, cells.count == columns * rows else { return ([], []) }
        var walls = Array<SurveyVertex?>(repeating: nil, count: columns)
        var furnishings = Array<SurveyVertex?>(repeating: nil, count: columns)
        for column in 0..<columns {
            var depths: [Double] = []
            for row in 0..<rows {
                let cell = cells[row * columns + column]
                if cell.confidence >= 1, cell.depth.isFinite, cell.depth > 0.05 {
                    depths.append(cell.depth)
                }
            }
            guard let far = depths.max(), let near = depths.min() else { continue }
            let bearing = columnBearing(column, columns: columns)
            let farFeet = far * feetPerMeter
            if NearbyScan.withinLimit(farFeet, rangeFeet: rangeFeet) {
                walls[column] = SurveyVertex(bearing: bearing, feet: farFeet)
            }
            if far - near >= furnitureGapMeters {
                let nearFeet = near * feetPerMeter
                if NearbyScan.withinLimit(nearFeet, rangeFeet: rangeFeet) {
                    furnishings[column] = SurveyVertex(bearing: bearing, feet: nearFeet)
                }
            }
        }
        return (runs(walls), runs(furnishings))
    }

    private static func runs(_ columns: [SurveyVertex?]) -> [[SurveyVertex]] {
        var runs: [[SurveyVertex]] = []
        var current: [SurveyVertex] = []
        for column in columns {
            if let column {
                current.append(column)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    private static func spanLabel(_ runs: [[SurveyVertex]], title: String) -> String? {
        let feet = runs.flatMap { $0 }.map(\.feet)
        guard let low = feet.min(), let high = feet.max() else { return nil }
        if abs(high - low) < 0.5 {
            return "\(title) \(Int(low.rounded())) ft"
        }
        return "\(title) \(Int(low.rounded()))–\(Int(high.rounded())) ft"
    }

    /// A GPS shift has to clear both this floor and the reported accuracy before a held wall comes down.
    static let moveFloorMeters = 8.0

    static func placeChanged(from anchor: SurveyPlace, to next: SurveyPlace) -> Bool {
        let accuracy = max(anchor.accuracyMeters, next.accuracyMeters, 0)
        return distanceMeters(anchor, next) > max(moveFloorMeters, accuracy)
    }

    static func distanceMeters(_ start: SurveyPlace, _ end: SurveyPlace) -> Double {
        let earth = 6_371_000.0
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLat = (end.latitude - start.latitude) * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let haversine = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earth * asin(min(1, sqrt(haversine)))
    }

    /// Keeps the first camera or LiDAR walls on the picture until the phone's place changes.
    struct Hold {
        var walls: [[SurveyVertex]] = []
        var furnishings: [[SurveyVertex]] = []
        private var anchor: SurveyPlace?

        mutating func note(place: SurveyPlace) -> Bool {
            guard let anchor else {
                self.anchor = place
                return false
            }
            guard RoomSurvey.placeChanged(from: anchor, to: place) else { return false }
            walls = []
            furnishings = []
            self.anchor = place
            return true
        }

        mutating func apply(to fresh: RoomPicture) -> RoomPicture {
            if walls.isEmpty, !fresh.walls.isEmpty {
                walls = fresh.walls
                furnishings = fresh.furnishings
            }
            guard !walls.isEmpty else { return fresh }
            return RoomSurvey.pinned(fresh, walls: walls, furnishings: furnishings)
        }
    }

    static func pinned(
        _ fresh: RoomPicture,
        walls: [[SurveyVertex]],
        furnishings: [[SurveyVertex]]
    ) -> RoomPicture {
        var lines: [String] = []
        if let label = spanLabel(walls, title: "Wall") {
            lines.append(label)
        }
        if let label = spanLabel(furnishings, title: "Near surface") {
            lines.append(label)
        }
        lines.append(contentsOf: fresh.lines.filter {
            !$0.hasPrefix("Wall ") && !$0.hasPrefix("Near surface ")
        })
        let positioned = walls.flatMap { $0 } + furnishings.flatMap { $0 }
        return RoomPicture(
            walls: walls,
            furnishings: furnishings,
            dot: centroid(positioned),
            lines: lines,
            rangeFeet: fresh.rangeFeet
        )
    }

    static func centroid(_ points: [SurveyVertex]) -> SurveyDot? {
        guard !points.isEmpty else { return nil }
        var x = 0.0
        var y = 0.0
        for point in points {
            x += sin(point.bearing) * point.feet
            y += cos(point.bearing) * point.feet
        }
        let count = Double(points.count)
        x /= count
        y /= count
        return SurveyDot(bearing: atan2(x, y), feet: hypot(x, y))
    }
}
