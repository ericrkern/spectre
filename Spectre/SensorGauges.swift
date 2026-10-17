import MapKit
import SwiftUI

enum DialScale {
    static func fraction(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0 }
        return Swift.min(Swift.max((value - min) / (max - min), 0), 1)
    }

    static func motion(_ g: Double) -> Double { fraction(g, min: 0, max: 1) }
    static func field(_ microtesla: Double) -> Double { fraction(microtesla, min: 0, max: 100) }
    static func pressure(_ kilopascals: Double) -> Double { fraction(kilopascals, min: 96, max: 106) }
    static func sound(_ decibels: Double) -> Double { fraction(decibels, min: -80, max: 0) }
    static func brightness(_ luma: Double) -> Double { fraction(luma, min: 0, max: 255) }
    static func depth(_ meters: Double) -> Double { fraction(meters, min: 0, max: 5) }
    static func steps(_ count: Double) -> Double { fraction(count, min: 0, max: 100) }
    static func acceleration(_ g: Double) -> Double { fraction(g, min: 0, max: 2) }
    static func rotation(_ radiansPerSecond: Double) -> Double { fraction(radiansPerSecond, min: 0, max: 5) }
    static func altitude(_ meters: Double) -> Double { fraction(meters, min: 0, max: 1000) }
    static func pace(_ secondsPerMeter: Double) -> Double { fraction(secondsPerMeter, min: 0, max: 2) }
    static func unit(_ value: Double) -> Double { fraction(value, min: 0, max: 1) }
}

struct SensorVisual: View {
    var widget: SensorWidgetState
    var compact = false
    var rangeFeet = DetectionSensitivity.standard.nearbyFeet
    var onScanTag: (() -> Void)? = nil
    var onTap: () -> Void = {}

    private var active: Bool {
        widget.status == .live && widget.reading != nil
    }

    var body: some View {
        switch widget.kind {
        case .compass:
            CompassDial(heading: active ? widget.reading : nil, label: widget.displayedValue, active: active)
        case .location:
            LocationDial(
                latitude: active ? widget.reading : nil,
                longitude: active ? widget.secondary : nil,
                label: widget.displayedValue,
                active: active
            )
        case .nearby:
            NearbyDevicesMeter(
                sightings: widget.sightings,
                rangeFeet: rangeFeet,
                compact: compact,
                onScanTag: onScanTag,
                onBackgroundTap: onTap
            )
        case .survey:
            SurveyMeter(
                picture: widget.picture,
                rangeFeet: rangeFeet,
                compact: compact,
                onBackgroundTap: onTap
            )
        case .microphone:
            SpectrumMeter(
                bands: widget.spectrum,
                label: widget.displayedValue,
                range: widget.caption.isEmpty ? Spectrum.rangeLabel(sampleRate: 48_000) : widget.caption,
                active: active && !widget.spectrum.isEmpty
            )
        default:
            NeedleDial(fraction: fraction, label: widget.displayedValue, active: active)
        }
    }

    private var fraction: Double {
        WidgetMetric.level(widget) ?? 0
    }
}

enum SensitivityDialMath {
    /// Maps a drag offset from the dial center onto 0...1 along the gauge arc.
    static func fraction(dx: Double, dy: Double) -> Double {
        guard dx != 0 || dy != 0 else { return 0.5 }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let start = 135.0
        let sweep = 270.0
        var delta = degrees - start
        if delta < 0 { delta += 360 }
        if delta > sweep {
            let gap = 360 - sweep
            return delta > sweep + gap / 2 ? 0 : 1
        }
        return delta / sweep
    }
}

struct SensitivityDial: View {
    @Binding var level: Double

    var body: some View {
        GeometryReader { geo in
            NeedleDial(
                fraction: level,
                label: DetectionSensitivity(level: level).label,
                active: true
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - geo.size.width / 2
                        let dy = value.location.y - geo.size.height / 2
                        level = SensitivityDialMath.fraction(dx: dx, dy: dy)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sensitivity")
        .accessibilityValue(DetectionSensitivity(level: level).label)
        .accessibilityIdentifier("sensitivity-dial")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                level = min(1, level + 0.05)
            case .decrement:
                level = max(0, level - 0.05)
            @unknown default:
                break
            }
        }
    }
}

struct SpectrumMeter: View {
    var bands: [Double]
    var label: String
    var range: String
    var active: Bool

    var body: some View {
        let shown = bands.isEmpty ? Array(repeating: 0.0, count: Spectrum.bandCount) : bands
        VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(shown.indices, id: \.self) { index in
                        Capsule()
                            .fill(active ? SpectreColor.gold : SpectreColor.line)
                            .frame(height: max(2, geo.size.height * shown[index]))
                    }
                }
            }
            HStack {
                Text(rangeEnd(first: true))
                Spacer(minLength: 4)
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text(rangeEnd(first: false))
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(active ? SpectreColor.ink : SpectreColor.muted)
        }
    }

    private func rangeEnd(first: Bool) -> String {
        let parts = range.components(separatedBy: " – ")
        let text = parts.count == 2 ? (first ? parts[0] : parts[1]) : (first ? "20 Hz" : "20 kHz")
        if text.hasSuffix(" kHz") {
            return text.replacingOccurrences(of: " kHz", with: "k")
        }
        if text.hasSuffix(" Hz") {
            return text.replacingOccurrences(of: " Hz", with: "")
        }
        return text
    }
}

struct NeedleDial: View {
    var fraction: Double
    var label: String
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let span = min(geo.size.width, geo.size.height)
            let stroke = min(8, max(2.5, span * 0.048))
            ZStack {
                DialArc(fraction: 1)
                    .stroke(SpectreColor.line, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                DialArc(fraction: fraction)
                    .stroke(active ? SpectreColor.gold : SpectreColor.muted, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                DialTicks()
                    .stroke(SpectreColor.muted, lineWidth: max(1, stroke * 0.22))
                DialNeedle(fraction: fraction)
                    .stroke(active ? SpectreColor.ink : SpectreColor.muted, style: StrokeStyle(lineWidth: max(1.5, stroke * 0.36), lineCap: .round))
                Circle()
                    .fill(active ? SpectreColor.gold : SpectreColor.muted)
                    .frame(width: max(4, span * 0.05), height: max(4, span * 0.05))
                Text(label)
                    .font(span > 200 ? .title2.weight(.semibold) : .caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(active ? SpectreColor.ink : SpectreColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .offset(y: span * 0.24)
                    .padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

private enum DialGeometry {
    static let start = Angle.degrees(135)
    static let sweep = 270.0

    static func point(in rect: CGRect, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: rect.midX + CGFloat(cos(angle.radians)) * radius,
            y: rect.midY + CGFloat(sin(angle.radians)) * radius
        )
    }

    static func radius(in rect: CGRect) -> CGFloat {
        let span = min(rect.width, rect.height)
        return span / 2 - max(4, span * 0.08)
    }
}

private struct DialArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return Path() }
        let radius = DialGeometry.radius(in: rect)
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: DialGeometry.start,
            endAngle: DialGeometry.start + .degrees(DialGeometry.sweep * clamped),
            clockwise: false
        )
        return path
    }
}

private struct DialTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = DialGeometry.radius(in: rect)
        let tick = max(3, radius * 0.16)
        var path = Path()
        for step in 0...4 {
            let angle = DialGeometry.start + .degrees(DialGeometry.sweep * Double(step) / 4)
            let outer = DialGeometry.point(in: rect, radius: radius - 1, angle: angle)
            let inner = DialGeometry.point(in: rect, radius: radius - tick, angle: angle)
            path.move(to: outer)
            path.addLine(to: inner)
        }
        return path
    }
}

private struct DialNeedle: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let angle = DialGeometry.start + .degrees(DialGeometry.sweep * min(max(fraction, 0), 1))
        let tip = DialGeometry.point(in: rect, radius: DialGeometry.radius(in: rect) * 0.72, angle: angle)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: tip)
        return path
    }
}

struct CompassDial: View {
    var heading: Double?
    var label: String
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let span = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .stroke(SpectreColor.line, lineWidth: min(8, max(2.5, span * 0.048)))
                ForEach(cardinalMarks, id: \.label) { mark in
                    Text(mark.label)
                        .font(.system(size: max(8, span * 0.08), weight: .bold))
                        .foregroundStyle(mark.label == "N" ? SpectreColor.gold : SpectreColor.muted)
                        .rotationEffect(.degrees(-mark.angle))
                        .offset(y: -span * 0.36)
                        .rotationEffect(.degrees(mark.angle))
                }
                CompassNeedle(active: active)
                    .frame(width: max(6, span * 0.08), height: span * 0.5)
                    .rotationEffect(.degrees(heading ?? 0))
                Text(label)
                    .font(.system(size: max(8, span * 0.09), weight: .semibold).monospacedDigit())
                    .foregroundStyle(active ? SpectreColor.ink : SpectreColor.muted)
                    .offset(y: span * 0.18)
            }
        }
        .animation(.easeOut(duration: 0.3), value: heading ?? 0)
    }

    private var cardinalMarks: [(label: String, angle: Double)] {
        [("N", 0), ("E", 90), ("S", 180), ("W", 270)]
    }
}

private struct CompassNeedle: View {
    var active: Bool

    var body: some View {
        Canvas { context, size in
            var north = Path()
            north.move(to: CGPoint(x: size.width / 2, y: 0))
            north.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            north.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2))
            north.closeSubpath()
            var south = Path()
            south.move(to: CGPoint(x: size.width / 2, y: size.height))
            south.addLine(to: CGPoint(x: 0, y: size.height / 2))
            south.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2))
            south.closeSubpath()
            context.fill(north, with: .color(active ? SpectreColor.gold : SpectreColor.muted))
            context.fill(south, with: .color(SpectreColor.muted))
        }
    }
}

struct SurveyMeter: View {
    var picture: RoomPicture
    var rangeFeet: Double
    var compact: Bool
    var onBackgroundTap: () -> Void = {}
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: compact ? 2 : 8) {
            GeometryReader { geo in
                let span = min(geo.size.width, geo.size.height)
                let radius = span / 2 - (compact ? 2 : 8)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .contentShape(Circle())
                        .frame(width: span, height: span)
                        .position(center)
                        .onTapGesture(perform: onBackgroundTap)
                    ForEach([1.0, 0.66, 0.33], id: \.self) { fraction in
                        Circle()
                            .stroke(SpectreColor.line, lineWidth: 1)
                            .frame(width: radius * 2 * fraction, height: radius * 2 * fraction)
                            .position(center)
                    }
                    Capsule()
                        .fill(SpectreColor.gold)
                        .frame(width: compact ? 2 : 3, height: compact ? 6 : 10)
                        .position(x: center.x, y: center.y - radius)
                    ForEach(picture.walls.indices, id: \.self) { index in
                        outline(picture.walls[index], color: SpectreColor.ink, width: compact ? 1.5 : 2.5, radius: radius, center: center)
                    }
                    ForEach(picture.furnishings.indices, id: \.self) { index in
                        outline(picture.furnishings[index], color: SpectreColor.gold, width: compact ? 1.5 : 3, radius: radius, center: center)
                    }
                }
            }
            .frame(maxHeight: compact ? .infinity : 190)
            if !compact {
                HStack(spacing: 12) {
                    legendSwatch(SpectreColor.ink, "Wall")
                    legendSwatch(SpectreColor.gold, "Near")
                }
                Button {
                    showDetail = true
                } label: {
                    Text(picture.dot?.distanceLabel ?? "Clear")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(SpectreColor.ink)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("survey-dot")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showDetail) {
            SurveyDetail(picture: picture)
        }
    }

    private func legendSwatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption2)
                .foregroundStyle(SpectreColor.muted)
        }
    }

    private func outline(_ vertices: [SurveyVertex], color: Color, width: CGFloat, radius: CGFloat, center: CGPoint) -> some View {
        Path { path in
            let points = vertices.compactMap { vertex -> CGPoint? in
                guard let plot = NearbyScan.plot(distanceFeet: vertex.feet, bearing: vertex.bearing, rangeFeet: rangeFeet) else { return nil }
                return CGPoint(x: center.x + plot.x * radius, y: center.y - plot.y * radius)
            }
            guard let first = points.first else { return }
            if points.count == 1 {
                path.move(to: CGPoint(x: first.x - 6, y: first.y))
                path.addLine(to: CGPoint(x: first.x + 6, y: first.y))
            } else {
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }
}

struct SurveyDetail: View {
    var picture: RoomPicture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Combined nearby")
                    .font(.headline)
                    .foregroundStyle(SpectreColor.ink)
                Spacer()
                Button("Close") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SpectreColor.gold)
            }
            if let dot = picture.dot {
                Text(dot.distanceLabel)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SpectreColor.ink)
                Text(dot.directionLabel)
                    .font(.body)
                    .foregroundStyle(SpectreColor.muted)
            } else {
                Text("Nothing in range")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SpectreColor.ink)
            }
            ForEach(picture.lines, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(SpectreColor.ink)
            }
            Text("Walls are the far depth in front of the phone. Near surfaces are closer than that wall. Wi-Fi is the network this phone has joined.")
                .font(.footnote)
                .foregroundStyle(SpectreColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SpectreColor.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("survey-detail")
    }
}

struct NearbyDevicesMeter: View {
    var sightings: [NearbySighting]
    var rangeFeet: Double
    var compact: Bool
    var onScanTag: (() -> Void)?
    var onBackgroundTap: () -> Void = {}
    @State private var selected: NearbySighting?

    private var shown: [NearbySighting] {
        sightings.filter { NearbyScan.withinLimit($0.distanceFeet, rangeFeet: rangeFeet) }
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 8) {
            NearbyRadar(
                sightings: shown,
                rangeFeet: rangeFeet,
                compact: compact,
                onSelect: { selected = $0 },
                onBackgroundTap: onBackgroundTap
            )
            .frame(maxHeight: compact ? .infinity : 190)
            if !compact {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .center, spacing: 6) {
                    ForEach(NearbySource.allCases, id: \.self) { source in
                        HStack(spacing: 4) {
                            Circle().fill(source.tint).frame(width: 8, height: 8)
                            Text(source.title)
                                .font(.caption2)
                                .foregroundStyle(SpectreColor.muted)
                                .lineLimit(1)
                        }
                    }
                }
                Text(NearbyScan.rangeLabel(feet: rangeFeet))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SpectreColor.ink)
                if let onScanTag {
                    Button("Read NFC tag", action: onScanTag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpectreColor.gold)
                        .accessibilityIdentifier("nearby-scan-tag")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selected) { sighting in
            NearbyDetail(sighting: sighting)
        }
    }
}

struct NearbyRadar: View {
    var sightings: [NearbySighting]
    var rangeFeet: Double
    var compact: Bool
    var onSelect: (NearbySighting) -> Void
    var onBackgroundTap: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let span = min(geo.size.width, geo.size.height)
            let radius = span / 2 - (compact ? 2 : 8)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dot = compact ? 4.0 : 7.0
            let hit = compact ? 16.0 : 28.0
            let unmeasured = sightings.filter { $0.bearing == nil }
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
                    .frame(width: span, height: span)
                    .position(center)
                    .onTapGesture(perform: onBackgroundTap)
                ForEach([1.0, 0.66, 0.33], id: \.self) { fraction in
                    Circle()
                        .stroke(SpectreColor.line, lineWidth: fraction == 1 ? (compact ? 1 : 1.5) : 1)
                        .frame(width: radius * 2 * fraction, height: radius * 2 * fraction)
                        .position(center)
                }
                Capsule()
                    .fill(SpectreColor.gold)
                    .frame(width: compact ? 2 : 3, height: compact ? 6 : 10)
                    .position(x: center.x, y: center.y - radius)
                Circle()
                    .fill(SpectreColor.gold)
                    .frame(width: compact ? 3 : 5, height: compact ? 3 : 5)
                    .position(center)
                ForEach(unmeasured) { sighting in
                    let fraction = displayedFraction(sighting.distanceFeet)
                    Circle()
                        .stroke(sighting.source.tint.opacity(0.45), lineWidth: 1)
                        .frame(width: radius * 2 * fraction, height: radius * 2 * fraction)
                        .position(center)
                        .allowsHitTesting(false)
                }
                ForEach(Array(sightings.enumerated()), id: \.element.id) { _, sighting in
                    if let point = point(for: sighting, unmeasured: unmeasured) {
                        Button {
                            onSelect(sighting)
                        } label: {
                            Circle()
                                .fill(sighting.source.tint)
                                .frame(width: dot, height: dot)
                                .frame(width: hit, height: hit)
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: center.x + CGFloat(point.x) * radius,
                            y: center.y - CGFloat(point.y) * radius
                        )
                        .accessibilityIdentifier("nearby-dot-\(sighting.id)")
                        .accessibilityLabel("\(sighting.source.title), \(sighting.name), \(sighting.distanceLabel), \(sighting.directionLabel)")
                        .accessibilityHint("Shows this detection")
                    }
                }
            }
        }
    }

    private func point(for sighting: NearbySighting, unmeasured: [NearbySighting]) -> (x: Double, y: Double)? {
        let raw: (x: Double, y: Double)?
        if sighting.bearing != nil {
            raw = NearbyScan.plot(distanceFeet: sighting.distanceFeet, bearing: sighting.bearing, rangeFeet: rangeFeet)
        } else if let slot = unmeasured.firstIndex(where: { $0.id == sighting.id }) {
            raw = NearbyScan.ringPoint(
                distanceFeet: sighting.distanceFeet,
                rangeFeet: rangeFeet,
                slot: slot,
                slots: unmeasured.count
            )
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        return lift(raw)
    }

    private func displayedFraction(_ feet: Double) -> Double {
        guard rangeFeet > 0 else { return 0 }
        return min(1, max(0.1, feet / rangeFeet))
    }

    private func lift(_ point: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let length = hypot(point.x, point.y)
        guard length > 0.0001 else { return (0, 0.1) }
        let shown = min(1, max(length, 0.1))
        let scale = shown / length
        return (point.x * scale, point.y * scale)
    }
}

struct NearbyDetail: View {
    var sighting: NearbySighting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(sighting.source.tint).frame(width: 16, height: 16)
                Text(sighting.source.title)
                    .font(.headline)
                    .foregroundStyle(SpectreColor.ink)
                Spacer()
                Button("Close") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SpectreColor.gold)
            }
            Text(sighting.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SpectreColor.ink)
            detailRow("Distance", sighting.distanceLabel)
            detailRow("Direction", sighting.directionLabel)
            detailRow("Signal", sighting.signal)
            if !sighting.note.isEmpty {
                detailRow("Detail", sighting.note)
            }
            detailRow("Seen", sighting.seenAt.formatted(date: .omitted, time: .standard))
            Text(sighting.source.rangeNote)
                .font(.footnote)
                .foregroundStyle(SpectreColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SpectreColor.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("nearby-detail")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SpectreColor.muted)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(SpectreColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension NearbySource {
    var tint: Color {
        switch self {
        case .bluetooth: Color(red: 0.42, green: 0.70, blue: 0.95)
        case .nfc: Color(red: 0.42, green: 0.80, blue: 0.58)
        case .ultraWideband: Color(red: 0.70, green: 0.54, blue: 0.95)
        case .proximity: Color(red: 0.95, green: 0.60, blue: 0.36)
        }
    }
}

struct RadarDial: View {
    var count: Int
    var label: String
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let span = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(SpectreColor.line, lineWidth: min(8, max(2.5, span * 0.048)))
                Circle().stroke(SpectreColor.line, lineWidth: 1).padding(span * 0.15)
                Circle().stroke(SpectreColor.line, lineWidth: 1).padding(span * 0.27)
                ForEach(0..<min(count, 12), id: \.self) { index in
                    Circle()
                        .fill(active ? SpectreColor.gold : SpectreColor.muted)
                        .frame(width: max(4, span * 0.055), height: max(4, span * 0.055))
                        .offset(y: -span * 0.31 + CGFloat(index % 3) * span * 0.09)
                        .rotationEffect(.degrees(Double(index) / Double(max(min(count, 12), 1)) * 360))
                }
                Text(label)
                    .font(.system(size: max(8, span * 0.1), weight: .semibold).monospacedDigit())
                    .foregroundStyle(active ? SpectreColor.ink : SpectreColor.muted)
            }
        }
        .animation(.easeOut(duration: 0.25), value: count)
    }
}

struct LocationDial: View {
    var latitude: Double?
    var longitude: Double?
    var label: String
    var active: Bool

    var body: some View {
        ZStack {
            if let latitude, let longitude, active {
                Map(position: .constant(.region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )))) {
                    Marker("Here", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                }
                .mapStyle(.standard(elevation: .flat))
                .clipShape(Circle())
                .allowsHitTesting(false)
            } else {
                GeometryReader { geo in
                    let span = min(geo.size.width, geo.size.height)
                    ZStack {
                        Circle().stroke(SpectreColor.line, lineWidth: min(8, max(2.5, span * 0.048)))
                        Rectangle()
                            .fill(SpectreColor.muted)
                            .frame(width: 1, height: span * 0.48)
                        Rectangle()
                            .fill(SpectreColor.muted)
                            .frame(width: span * 0.48, height: 1)
                        Circle()
                            .stroke(SpectreColor.gold.opacity(active ? 1 : 0.4), lineWidth: 1.5)
                            .frame(width: span * 0.2, height: span * 0.2)
                    }
                }
            }
            if latitude == nil || longitude == nil || !active {
                GeometryReader { geo in
                    Text(label)
                        .font(.system(size: max(8, min(geo.size.width, geo.size.height) * 0.1), weight: .semibold).monospacedDigit())
                        .foregroundStyle(SpectreColor.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: min(geo.size.width, geo.size.height) * 0.24)
                }
            }
        }
    }
}
