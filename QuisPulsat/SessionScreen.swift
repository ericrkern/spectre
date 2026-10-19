import CoreNFC
import SwiftUI

struct SessionScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: DashboardController
    @State private var showDetections = false

    @MainActor
    init() {
        _controller = State(initialValue: DashboardController())
    }

    init(controller: DashboardController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QuisPulsatColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        sensorBoard
                        captureControls
                        if !controller.captures.isEmpty {
                            savedList
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Quis Pulsat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(isPresented: $showDetections) {
                DetectionsScreen(controller: controller)
            }
        }
        .preferredColorScheme(.dark)
        .tint(QuisPulsatColor.gold)
        .onAppear {
            controller.activate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.activate()
            } else {
                controller.suspend()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("QuisPulsatHero")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Quis Pulsat. Something's knocking. Dare to answer?")
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(controller.elapsedLabel(at: ContinuousClock().now))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(QuisPulsatColor.gold)
                    .accessibilityIdentifier("session-clock")
            }
            Text("Sensors stay live while Quis Pulsat is open. Capture saves what they show right now.")
                .font(.subheadline)
                .foregroundStyle(QuisPulsatColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Image("QuisPulsatHowItWorks")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Set the phone down, learn the room, then keep each lead on its own.")
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 4) {
                    Text("Sensitivity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(QuisPulsatColor.muted)
                    SensitivityDial(level: $controller.sensitivityLevel)
                        .frame(width: 132, height: 132)
                }
                Button {
                    showDetections = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detections")
                            .font(.headline)
                        Text(controller.detections.isEmpty ? "None yet" : "\(controller.detections.count)")
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(QuisPulsatColor.gold)
                    .foregroundStyle(QuisPulsatColor.background)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detections-button")
            }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Place name", text: $controller.placeName)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(16)
                .background(QuisPulsatColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("place-name")
                .autocorrectionDisabled()

            Button("Capture and save") {
                controller.capture()
            }
            .buttonStyle(QuisPulsatButtonStyle())
            .disabled(!controller.canCapture)
            .accessibilityIdentifier("capture-save")
        }
    }

    private var sensorBoard: some View {
        VStack(spacing: 16) {
            if let featured = controller.feed.widgets.first(where: { $0.kind == controller.featuredKind }) {
                SensorWidget(
                    widget: featured,
                    rangeFeet: controller.sensitivity.nearbyFeet,
                    onScanTag: NFCNDEFReaderSession.readingAvailable ? { controller.feed.enable(.nfc) } : nil
                ) {
                    controller.focus(featured.kind)
                }
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(controller.feed.widgets.filter { $0.kind != controller.featuredKind }) { widget in
                        SensorWidget(widget: widget, compact: true, rangeFeet: controller.sensitivity.nearbyFeet) {
                            controller.focus(widget.kind)
                        }
                        .frame(width: 96)
                    }
                }
            }
        }
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved")
                .font(.headline)
                .foregroundStyle(QuisPulsatColor.ink)
            VStack(spacing: 0) {
                ForEach(controller.captures) { capture in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(capture.placeName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(QuisPulsatColor.ink)
                        Text("\(capture.elapsed) · \(capture.savedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(QuisPulsatColor.muted)
                        Text(capture.summary)
                            .font(.subheadline)
                            .foregroundStyle(QuisPulsatColor.gold)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("saved-\(capture.placeName)")
                    if capture.id != controller.captures.last?.id {
                        Divider().overlay(QuisPulsatColor.line)
                    }
                }
            }
            .background(QuisPulsatColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct DetectionsScreen: View {
    var controller: DashboardController

    var body: some View {
        ZStack {
            QuisPulsatColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    leadList
                }
                .padding(20)
            }
        }
        .navigationTitle("Detections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var leadList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leads")
                .font(.headline)
                .foregroundStyle(QuisPulsatColor.ink)
            Text(controller.watchStatus)
                .font(.subheadline)
                .foregroundStyle(QuisPulsatColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lead-status")
            Text(controller.sensitivity.summary)
                .font(.caption)
                .foregroundStyle(QuisPulsatColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("detection-thresholds")
            if !controller.soundStatus.isEmpty {
                Text(controller.soundStatus)
                    .font(.subheadline)
                    .foregroundStyle(QuisPulsatColor.muted)
                    .accessibilityIdentifier("sound-status")
            }
            if !controller.headingStatus.isEmpty {
                Text(controller.headingStatus)
                    .font(.subheadline)
                    .foregroundStyle(QuisPulsatColor.muted)
                    .accessibilityIdentifier("heading-status")
            }
            if !controller.brightnessStatus.isEmpty {
                Text(controller.brightnessStatus)
                    .font(.subheadline)
                    .foregroundStyle(QuisPulsatColor.muted)
                    .accessibilityIdentifier("brightness-status")
            }
            if !controller.depthStatus.isEmpty {
                Text(controller.depthStatus)
                    .font(.subheadline)
                    .foregroundStyle(QuisPulsatColor.muted)
                    .accessibilityIdentifier("depth-status")
            }
            if !controller.radioStatus.isEmpty {
                Text(controller.radioStatus)
                    .font(.subheadline)
                    .foregroundStyle(QuisPulsatColor.muted)
                    .accessibilityIdentifier("radio-status")
            }
            if let detection = controller.announced {
                detectionBanner(detection)
            }
            if !controller.leadGroups.isEmpty {
                VStack(spacing: 0) {
                    ForEach(controller.leadGroups) { group in
                        if group.sameMoment {
                            Text("Same moment")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(QuisPulsatColor.gold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .accessibilityIdentifier("same-moment")
                        }
                        ForEach(group.detections) { detection in
                            detectionRow(detection)
                            if detection.id != controller.leadGroups.last?.detections.last?.id {
                                Divider().overlay(QuisPulsatColor.line)
                            }
                        }
                    }
                }
                .background(QuisPulsatColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func detectionRow(_ detection: SavedDetection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detection.title)
                .font(.body.weight(.medium))
                .foregroundStyle(QuisPulsatColor.ink)
            Text("\(detection.feature) · \(detection.magnitudeLabel)")
                .font(.subheadline)
                .foregroundStyle(QuisPulsatColor.gold)
            Text("Threshold \(detection.thresholdLabel)")
                .font(.subheadline)
                .foregroundStyle(QuisPulsatColor.muted)
            Text("\(detection.placeName) · \(detection.elapsed)")
                .font(.caption)
                .foregroundStyle(QuisPulsatColor.muted)
            if !detection.sampleLabel.isEmpty {
                Text("Window \(detection.sampleLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(QuisPulsatColor.muted)
                    .lineLimit(3)
            }
            if detection.clipWAV != nil {
                Button("Play clip") {
                    if let clip = detection.clipWAV {
                        ClipPlayback.shared.play(clip)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(QuisPulsatColor.background)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(QuisPulsatColor.gold)
                .clipShape(Capsule())
                .padding(.top, 6)
                .accessibilityIdentifier("play-clip")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-\(detection.kind)")
    }

    private func detectionBanner(_ detection: SavedDetection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.announcedCount > 1 ? "Detected \(controller.announcedCount)" : "Detected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(QuisPulsatColor.background)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(QuisPulsatColor.gold)
                .clipShape(Capsule())
            Text(detection.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(QuisPulsatColor.ink)
            Text(detection.magnitudeLabel)
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(QuisPulsatColor.gold)
            Text("\(detection.feature) crossed \(detection.thresholdLabel)")
                .font(.subheadline)
                .foregroundStyle(QuisPulsatColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(QuisPulsatColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(QuisPulsatColor.gold, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detection-banner")
    }
}

private struct SensorWidget: View {
    var widget: SensorWidgetState
    var compact = false
    var rangeFeet = DetectionSensitivity.standard.nearbyFeet
    var onScanTag: (() -> Void)? = nil
    var onTap: () -> Void

    var body: some View {
        if widget.kind == .nearby || widget.kind == .survey {
            card
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sensor-\(widget.kind.rawValue)")
        } else {
            Button(action: onTap) {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sensor-\(widget.kind.rawValue)")
            .accessibilityLabel("\(widget.kind.displayName), \(widget.displayedValue), \(widget.caption), \(widget.status.label). \(widget.status.detail)")
        }
    }

    private var card: some View {
        VStack(spacing: compact ? 4 : 8) {
            focusable(
                Text(widget.kind.displayName)
                    .font(compact ? .caption2.weight(.medium) : .headline)
                    .foregroundStyle(compact ? QuisPulsatColor.muted : QuisPulsatColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            )
            SensorVisual(widget: widget, compact: compact, rangeFeet: rangeFeet, onScanTag: compact ? nil : onScanTag, onTap: onTap)
                .frame(height: compact ? 72 : 260)
                .frame(maxWidth: .infinity)
            if !compact, !widget.caption.isEmpty {
                focusable(
                    Text(widget.caption)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(QuisPulsatColor.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                )
            }
            focusable(
                Text(widget.status.label)
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(widget.status.tint)
            )
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 108 : 320, alignment: .center)
        .padding(.horizontal, compact ? 4 : 16)
        .padding(.vertical, compact ? 8 : 16)
        .background(QuisPulsatColor.card)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 20))
    }

    @ViewBuilder
    private func focusable<V: View>(_ content: V) -> some View {
        if widget.kind == .nearby || widget.kind == .survey {
            content.onTapGesture(perform: onTap)
        } else {
            content
        }
    }
}

private struct QuisPulsatButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(QuisPulsatColor.gold.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35))
            .foregroundStyle(QuisPulsatColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

enum QuisPulsatColor {
    static let background = Color(red: 0.063, green: 0.078, blue: 0.106)
    static let card = Color(red: 0.102, green: 0.129, blue: 0.188)
    static let ink = Color(red: 0.957, green: 0.965, blue: 0.980)
    static let muted = Color(red: 0.718, green: 0.761, blue: 0.824)
    static let gold = Color(red: 0.894, green: 0.769, blue: 0.541)
    static let line = Color(red: 0.192, green: 0.251, blue: 0.337)
}

private extension SensorStatus {
    var tint: Color {
        switch self {
        case .live: QuisPulsatColor.gold
        case .denied: Color(red: 0.878, green: 0.478, blue: 0.416)
        case .unavailable, .notAsked: QuisPulsatColor.muted
        }
    }
}

private extension SavedCapture {
    var summary: String {
        let live = sensors.filter { $0.status == "Live" && $0.value != "—" }
        if live.isEmpty {
            return "No live readings"
        }
        return live.prefix(3).map { "\($0.name) \($0.value)" }.joined(separator: " · ")
    }
}
