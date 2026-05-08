import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PPGCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.ppgCSV]

    let csv: String

    init(csv: String) {
        self.csv = csv
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let csv = String(data: data, encoding: .utf8) {
            self.csv = csv
        } else {
            self.csv = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(csv.utf8))
    }
}

extension UTType {
    static let ppgCSV = UTType(filenameExtension: "csv") ?? .plainText
}

struct DashboardView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var isExportingCSV = false
    @State private var isShowingDevicePicker = false

    private let redLineColor = Color(red: 0.83, green: 0.18, blue: 0.28)
    private let irLineColor = Color(red: 0.15, green: 0.37, blue: 0.82)
    private let greenLineColor = Color(red: 0.09, green: 0.58, blue: 0.36)
    private let statusColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]
    private let controlColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        statusCard
                        controlsCard
                        chartCard
                        logCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: PPGCSVDocument(csv: appModel.csvContent),
            contentType: .ppgCSV,
            defaultFilename: appModel.exportFilename
        ) { result in
            appModel.handleExportResult(result)
        }
        .sheet(isPresented: $isShowingDevicePicker) {
            devicePickerSheet
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("JingQi PPG")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }

            Label(appModel.connectionState.title, systemImage: statusIcon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            LazyVGrid(columns: statusColumns, spacing: 12) {
                metricTile(title: "Red", value: appModel.currentRedText)
                metricTile(title: "IR", value: appModel.currentIRText)
                metricTile(title: "Green", value: appModel.currentGreenText)
            }

            metricTile(title: "Period", value: appModel.periodAnalysis.periodText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Controls",
                subtitle: "Scan, connect, and control the MAX30101 board."
            )

            HStack(spacing: 12) {
                actionButton(title: "Scan", systemImage: "dot.radiowaves.left.and.right", style: .primary) {
                    isShowingDevicePicker = true
                    appModel.startDeviceScan()
                }

                actionButton(
                    title: "Disconnect",
                    systemImage: "xmark.circle",
                    style: .secondary,
                    isDisabled: !appModel.canControlStreaming,
                    action: appModel.disconnect
                )
            }

            LazyVGrid(columns: controlColumns, spacing: 12) {
                actionButton(
                    title: "Start",
                    systemImage: "play.fill",
                    style: .primary,
                    isDisabled: !appModel.canControlStreaming,
                    action: appModel.sendStart
                )

                actionButton(
                    title: "Pause",
                    systemImage: "pause.fill",
                    style: .secondary,
                    isDisabled: !appModel.canControlStreaming,
                    action: appModel.sendPause
                )

                actionButton(
                    title: "I2C Scan",
                    systemImage: "magnifyingglass",
                    style: .secondary,
                    isDisabled: !appModel.canControlStreaming,
                    action: appModel.sendScanI2C
                )

                actionButton(
                    title: "Reset",
                    systemImage: "arrow.clockwise",
                    style: .secondary,
                    isDisabled: !appModel.canControlStreaming,
                    action: appModel.sendReset
                )
            }

            HStack(spacing: 12) {
                actionButton(
                    title: "Clear Data",
                    systemImage: "trash",
                    style: .danger,
                    isDisabled: !appModel.canClearCapturedData,
                    action: appModel.clearCapturedData
                )

                actionButton(
                    title: "Save CSV",
                    systemImage: "square.and.arrow.down",
                    style: .success,
                    isDisabled: !appModel.canExportSamples
                ) {
                    isExportingCSV = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Live PPG",
                subtitle: appModel.chartSummaryText
            )

            if appModel.chartSamples.isEmpty {
                ContentUnavailableView(
                    "No Live Data Yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Scan and connect to JingQiPPG, then tap Start to begin streaming.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            } else if let timeDomain = appModel.chartTimeDomain {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        chartLegendLabel(color: redLineColor, title: "Red")
                        chartLegendLabel(color: irLineColor, title: "IR")
                        chartLegendLabel(color: greenLineColor, title: "Green")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(PPGChannel.allCases) { channel in
                        channelPlotSection(channel: channel, timeDomain: timeDomain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Device Log",
                subtitle: "Raw BLE events and app-side diagnostics."
            )

            if appModel.logEntries.isEmpty {
                Text("Logs from the MAX30101 board will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(appModel.logEntries) { entry in
                                Text(entry.renderedText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(height: 220)
                    .onChange(of: appModel.logEntries.last?.id, initial: true) { _, lastID in
                        guard let lastID else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private func channelPlotSection(channel: PPGChannel, timeDomain: ClosedRange<Date>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                chartLegendLabel(color: channelColor(channel), title: channel.label)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(appModel.channelRangeText(for: channel))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let valueDomain = appModel.channelDomain(for: channel) {
                PPGChannelPlot(
                    samples: appModel.plottedChartSamples,
                    channel: channel,
                    valueDomain: valueDomain,
                    timeDomain: timeDomain,
                    color: channelColor(channel)
                )
                .frame(height: 148)
            }

            Divider()
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func actionButton(
        title: String,
        systemImage: String,
        style: ActionButtonStyleKind,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))

                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }
            .foregroundStyle(buttonForeground(style: style, isDisabled: isDisabled))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(buttonBackground(style: style, isDisabled: isDisabled))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(buttonBorder(style: style, isDisabled: isDisabled), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func discoveredDeviceRow(_ device: BLEDiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.connectionLabel)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(device.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Connect")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.black)
                )
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartLegendLabel(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 16, height: 4)

            Text(title)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private var devicePickerSheet: some View {
        NavigationStack {
            Group {
                if appModel.discoveredDevices.isEmpty {
                    ContentUnavailableView(
                        appModel.isScanningForDevices ? "Scanning for Boards" : "No Boards Found",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Keep JingQiPPG powered on and nearby. Nordic UART devices with the PPG service will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        Section("Nearby Boards") {
                            ForEach(appModel.discoveredDevices) { device in
                                Button {
                                    appModel.connect(to: device.id)
                                    isShowingDevicePicker = false
                                } label: {
                                    discoveredDeviceRow(device)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Text("Tap a board below to connect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(Color(.systemBackground))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        isShowingDevicePicker = false
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan") {
                        appModel.startDeviceScan()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            appModel.startDeviceScan()
        }
        .onDisappear {
            appModel.stopDeviceScan()
        }
    }

    private var statusIcon: String {
        switch appModel.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting, .scanning:
            return "dot.radiowaves.left.and.right"
        case .unauthorized:
            return "lock.slash"
        case .bluetoothUnavailable:
            return "bolt.slash.fill"
        case .idle:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func channelColor(_ channel: PPGChannel) -> Color {
        switch channel {
        case .red:
            return redLineColor
        case .ir:
            return irLineColor
        case .green:
            return greenLineColor
        }
    }

    private func buttonBackground(style: ActionButtonStyleKind, isDisabled: Bool) -> Color {
        if isDisabled {
            return Color(.systemGray5)
        }

        switch style {
        case .primary:
            return .black
        case .secondary:
            return Color(.secondarySystemBackground)
        case .danger:
            return Color(red: 0.90, green: 0.34, blue: 0.29)
        case .success:
            return Color(red: 0.17, green: 0.67, blue: 0.36)
        }
    }

    private func buttonForeground(style: ActionButtonStyleKind, isDisabled: Bool) -> Color {
        if isDisabled {
            return .secondary
        }

        switch style {
        case .primary:
            return .white
        case .secondary:
            return .primary
        case .danger, .success:
            return .white
        }
    }

    private func buttonBorder(style: ActionButtonStyleKind, isDisabled: Bool) -> Color {
        if isDisabled {
            return Color(.systemGray4)
        }

        switch style {
        case .primary:
            return .black
        case .secondary:
            return Color.black.opacity(0.08)
        case .danger:
            return Color(red: 0.90, green: 0.34, blue: 0.29)
        case .success:
            return Color(red: 0.17, green: 0.67, blue: 0.36)
        }
    }
}

private enum ActionButtonStyleKind {
    case primary
    case secondary
    case danger
    case success
}

private struct PPGChannelPlot: View {
    let samples: [PPGSample]
    let channel: PPGChannel
    let valueDomain: ClosedRange<Double>
    let timeDomain: ClosedRange<Date>
    let color: Color

    private let leadingAxisWidth: CGFloat = 48
    private let rightPadding: CGFloat = 12
    private let bottomAxisHeight: CGFloat = 24
    private let topPadding: CGFloat = 10
    private let horizontalTickCount = 4
    private let verticalTickCount = 4

    var body: some View {
        GeometryReader { geometry in
            let plotRect = CGRect(
                x: leadingAxisWidth,
                y: topPadding,
                width: max(geometry.size.width - leadingAxisWidth - rightPadding, 1),
                height: max(geometry.size.height - topPadding - bottomAxisHeight, 1)
            )

            ZStack {
                Canvas { context, _ in
                    drawGrid(context: &context, plotRect: plotRect)
                    drawLine(context: &context, plotRect: plotRect)
                    drawLatestMarker(context: &context, plotRect: plotRect)
                }

                axisOverlay(plotRect: plotRect)
            }
        }
    }

    private func axisOverlay(plotRect: CGRect) -> some View {
        ZStack {
            VStack(alignment: .leading) {
                Text(axisLabel(valueDomain.upperBound))
                Spacer(minLength: 0)
                Text(axisLabel(valueDomain.lowerBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .padding(.top, topPadding - 2)
            .padding(.bottom, bottomAxisHeight - 2)

            VStack {
                Spacer(minLength: 0)
                HStack {
                    Text("0s")
                    Spacer(minLength: 0)
                    Text(totalSecondsText)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, plotRect.minX)
                .padding(.trailing, rightPadding)
            }
            .padding(.bottom, 1)
        }
    }

    private func drawGrid(context: inout GraphicsContext, plotRect: CGRect) {
        guard horizontalTickCount > 1, verticalTickCount > 1 else { return }

        for index in 0..<horizontalTickCount {
            let ratio = Double(index) / Double(horizontalTickCount - 1)
            let y = plotRect.maxY - (plotRect.height * ratio)
            var path = Path()
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(path, with: .color(Color(.separator).opacity(0.5)), lineWidth: 1)
        }

        for index in 1..<(verticalTickCount - 1) {
            let ratio = Double(index) / Double(verticalTickCount - 1)
            let x = plotRect.minX + (plotRect.width * ratio)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(
                path,
                with: .color(Color(.separator).opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        }
    }

    private func drawLine(context: inout GraphicsContext, plotRect: CGRect) {
        guard samples.count >= 2 else { return }

        var path = Path()

        for (index, sample) in samples.enumerated() {
            let point = point(for: sample, plotRect: plotRect)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawLatestMarker(context: inout GraphicsContext, plotRect: CGRect) {
        guard let latest = samples.last else { return }

        let point = point(for: latest, plotRect: plotRect)
        let markerRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: markerRect), with: .color(color))
    }

    private func point(for sample: PPGSample, plotRect: CGRect) -> CGPoint {
        let timeSpan = max(timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound), 0.001)
        let xRatio = sample.timestamp.timeIntervalSince(timeDomain.lowerBound) / timeSpan
        let valueSpan = max(valueDomain.upperBound - valueDomain.lowerBound, 1.0)
        let yRatio = (Double(sample.value(for: channel)) - valueDomain.lowerBound) / valueSpan
        let x = plotRect.minX + plotRect.width * xRatio
        let y = plotRect.maxY - plotRect.height * yRatio
        return CGPoint(x: x, y: y)
    }

    private var totalSecondsText: String {
        let seconds = timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound)
        return "\(String(format: "%.2f", seconds))s"
    }

    private func axisLabel(_ value: Double) -> String {
        if value >= 100_000 {
            return String(format: "%.0fk", value / 1000.0)
        }

        return "\(Int(value.rounded()))"
    }
}
