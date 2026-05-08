import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connectionState: BLEConnectionState = .idle
    @Published private(set) var discoveredDevices: [BLEDiscoveredDevice] = []
    @Published private(set) var samples: [PPGSample] = []
    @Published private(set) var temperatureSamples: [TemperatureSample] = []
    @Published private(set) var sensorHealth: SensorHealth = .unknown
    @Published private(set) var isStreaming = false
    @Published private(set) var sentSamples: Int?
    @Published private(set) var droppedSamples: Int?
    @Published private(set) var latestSample: PPGSample?
    @Published private(set) var periodAnalysis: PeriodAnalysis = .collecting
    @Published private(set) var logEntries: [DeviceLogEntry] = []

    let bleManager = BLEManager()

    private var parser = PPGPacketParser()
    private var rawLogBuffer = ""
    private var streamStartDate: Date?
    private var lastStreamTimeMs: Int?

    private let displayedChartSampleLimit = 320
    private let logEntryLimit = 250
    private let displayedTemperatureSampleLimit = 120
    private let fallbackSampleIntervalMs = 10
    private let validTemperatureRange = -40.0 ... 85.0
    private let maxAcceptedTemperatureJumpC = 5.0
    private let maxAcceptedTemperatureJumpInterval: TimeInterval = 5.0
    private let ppgMinPeriodMs = 400.0
    private let ppgMaxPeriodMs = 1_500.0
    private let periodVariationLimit = 0.28

    init() {
        bleManager.onStateChange = { [weak self] state in
            self?.connectionState = state
        }

        bleManager.onDiscoveredDevicesChange = { [weak self] devices in
            self?.discoveredDevices = devices
        }

        bleManager.onPayload = { [weak self] data in
            self?.handleIncomingPayload(data)
        }

        bleManager.onLog = { [weak self] message in
            self?.appendMessage(message)
        }

        bleManager.start()
    }

    var currentRedText: String {
        guard let latestSample else { return "--" }
        return "\(latestSample.red)"
    }

    var currentIRText: String {
        guard let latestSample else { return "--" }
        return "\(latestSample.ir)"
    }

    var currentGreenText: String {
        guard let latestSample else { return "--" }
        return "\(latestSample.green)"
    }

    var currentTemperatureText: String {
        guard let temperatureC = temperatureSamples.last?.temperatureC else { return "--" }
        return String(format: "%.2f °C", temperatureC)
    }

    var sampleStatusText: String {
        guard let latestSample else {
            return "0 samples"
        }

        return "\(samples.count) samples / \(latestSample.streamTimeMs) ms"
    }

    var transferStatusText: String {
        guard let sentSamples else { return "--" }
        let dropped = droppedSamples ?? 0
        return "\(sentSamples) sent / \(dropped) dropped"
    }

    var streamStatusText: String {
        isStreaming ? "Stream On" : "Stream Off"
    }

    var canControlStreaming: Bool {
        if case .connected = connectionState {
            return true
        }

        return false
    }

    var isScanningForDevices: Bool {
        if case .scanning = connectionState {
            return true
        }

        return false
    }

    var canExportSamples: Bool {
        !samples.isEmpty
    }

    var canClearCapturedData: Bool {
        !samples.isEmpty || !temperatureSamples.isEmpty || !logEntries.isEmpty || latestSample != nil
    }

    var chartSamples: [PPGSample] {
        Array(samples.suffix(displayedChartSampleLimit))
    }

    var plottedChartSamples: [PPGSample] {
        chartSamples.sorted { $0.timestamp < $1.timestamp }
    }

    var chartTimeDomain: ClosedRange<Date>? {
        guard let first = plottedChartSamples.first?.timestamp, let last = plottedChartSamples.last?.timestamp else {
            return nil
        }

        if first == last {
            return first ... first.addingTimeInterval(1.0)
        }

        return first ... last
    }

    var chartSummaryText: String {
        let visibleSamples = plottedChartSamples

        guard
            let first = visibleSamples.first,
            let last = visibleSamples.last
        else {
            return "Waiting for live PPG samples."
        }

        let seconds = last.timestamp.timeIntervalSince(first.timestamp)
        return "\(visibleSamples.count) pts • \(String(format: "%.2f", seconds))s • \(periodAnalysis.statusText)"
    }

    var exportFilename: String {
        "ppg-\(Self.exportDateFormatter.string(from: Date()))"
    }

    var csvContent: String {
        let rows = samples.enumerated().map { index, sample in
            let deltaMS: String

            if index == 0 {
                deltaMS = ""
            } else {
                let previousSample = samples[index - 1]
                deltaMS = "\(sample.streamTimeMs - previousSample.streamTimeMs)"
            }

            return "\(Self.csvDateFormatter.string(from: sample.timestamp)),\(sample.streamTimeMs),\(sample.red),\(sample.ir),\(sample.green),\(deltaMS)"
        }

        return (["time,stream_time_ms,red,ir,green,delta_stream_ms"] + rows).joined(separator: "\n")
    }

    func channelDomain(for channel: PPGChannel) -> ClosedRange<Double>? {
        let values = plottedChartSamples.map { $0.value(for: channel) }

        guard let minValue = values.min(), let maxValue = values.max() else {
            return nil
        }

        let span = Double(maxValue - minValue)
        let padding = max(span * 0.08, 20.0)
        let lowerBound = max(0.0, Double(minValue) - padding)
        let upperBound = Double(maxValue) + padding

        if lowerBound == upperBound {
            return max(0.0, lowerBound - 1.0) ... (upperBound + 1.0)
        }

        return lowerBound ... upperBound
    }

    func channelRangeText(for channel: PPGChannel) -> String {
        let values = plottedChartSamples.map { $0.value(for: channel) }

        guard
            let minValue = values.min(),
            let maxValue = values.max(),
            let first = plottedChartSamples.first,
            let last = plottedChartSamples.last
        else {
            return "--"
        }

        let seconds = last.timestamp.timeIntervalSince(first.timestamp)
        return "\(minValue)-\(maxValue) / \(String(format: "%.2f", seconds))s"
    }

    func startDeviceScan() {
        bleManager.startScan()
    }

    func stopDeviceScan() {
        bleManager.stopScan()
    }

    func connect(to deviceID: UUID) {
        bleManager.connect(to: deviceID)
    }

    func disconnect() {
        bleManager.disconnect()
    }

    func sendStart() {
        bleManager.sendCommand("S")
    }

    func sendPause() {
        bleManager.sendCommand("P")
    }

    func sendScanI2C() {
        bleManager.sendCommand("C")
    }

    func sendReset() {
        bleManager.sendCommand("R")
    }

    func sendTemperatureQuery() {
        bleManager.sendCommand("T")
    }

    func sendHelp() {
        bleManager.sendCommand("H")
    }

    func clearCapturedData() {
        samples.removeAll(keepingCapacity: true)
        temperatureSamples.removeAll(keepingCapacity: true)
        logEntries.removeAll(keepingCapacity: true)
        latestSample = nil
        sensorHealth = .unknown
        sentSamples = nil
        droppedSamples = nil
        periodAnalysis = .collecting
        rawLogBuffer = ""
        streamStartDate = nil
        lastStreamTimeMs = nil
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            appendMessage("Saved CSV: \(url.lastPathComponent)")
        case .failure(let error):
            appendMessage("CSV export failed: \(error.localizedDescription)")
        }
    }

    private func handleIncomingPayload(_ data: Data) {
        logRawPayload(data)

        for event in parser.consume(data) {
            switch event {
            case .batch(let packetSamples):
                ingestBatch(packetSamples)
            case .legacySample(let red, let ir, let green):
                ingestLegacySample(red: red, ir: ir, green: green)
            case .temperature(let temperatureC):
                ingestTemperature(temperatureC)
            case .streamState(let enabled):
                isStreaming = enabled
                if enabled {
                    prepareForFreshStream()
                }
            case .status(let sent, let dropped):
                sentSamples = sent
                droppedSamples = dropped
            case .sensorHealth(let health, let message):
                sensorHealth = health
                appendMessage(message)
            case .message(let message):
                appendMessage(message)
            }
        }
    }

    private func prepareForFreshStream() {
        streamStartDate = nil
        lastStreamTimeMs = nil
        sentSamples = nil
        droppedSamples = nil
    }

    private func ingestBatch(_ packetSamples: [PPGPacketSample]) {
        guard !packetSamples.isEmpty else { return }

        let now = Date()
        let lastPacketTimeMs = packetSamples.last?.timeMs ?? 0

        if streamStartDate == nil || shouldResetStreamTimeline(for: packetSamples.first?.timeMs) {
            streamStartDate = now.addingTimeInterval(-Double(lastPacketTimeMs) / 1000.0)
        }

        let baseDate = streamStartDate ?? now
        let newSamples = packetSamples.map { packetSample in
            PPGSample(
                timestamp: baseDate.addingTimeInterval(Double(packetSample.timeMs) / 1000.0),
                streamTimeMs: packetSample.timeMs,
                red: packetSample.red,
                ir: packetSample.ir,
                green: packetSample.green
            )
        }

        samples.append(contentsOf: newSamples)
        latestSample = newSamples.last
        lastStreamTimeMs = packetSamples.last?.timeMs
        sensorHealth = .normal
        periodAnalysis = analyzePeriod(samples: Array(samples.suffix(displayedChartSampleLimit)), channel: .ir)
    }

    private func shouldResetStreamTimeline(for incomingTimeMs: Int?) -> Bool {
        guard let incomingTimeMs, let lastStreamTimeMs else { return false }
        return incomingTimeMs < lastStreamTimeMs
    }

    private func ingestLegacySample(red: Int, ir: Int, green: Int) {
        let streamTimeMs = (lastStreamTimeMs ?? -fallbackSampleIntervalMs) + fallbackSampleIntervalMs
        let sample = PPGSample(
            timestamp: Date(),
            streamTimeMs: streamTimeMs,
            red: red,
            ir: ir,
            green: green
        )

        samples.append(sample)
        latestSample = sample
        lastStreamTimeMs = streamTimeMs
        sensorHealth = .normal
        periodAnalysis = analyzePeriod(samples: Array(samples.suffix(displayedChartSampleLimit)), channel: .ir)
    }

    private func ingestTemperature(_ temperatureC: Double) {
        guard validTemperatureRange.contains(temperatureC) else {
            appendMessage("Ignored invalid temperature sample: \(String(format: "%.3f", temperatureC)) °C")
            return
        }

        if let lastSample = temperatureSamples.last {
            let deltaT = Date().timeIntervalSince(lastSample.timestamp)
            let deltaC = abs(temperatureC - lastSample.temperatureC)
            if deltaT <= maxAcceptedTemperatureJumpInterval, deltaC > maxAcceptedTemperatureJumpC {
                appendMessage(
                    "Ignored temperature outlier: \(String(format: "%.3f", temperatureC)) °C after \(String(format: "%.3f", lastSample.temperatureC)) °C"
                )
                return
            }
        }

        temperatureSamples.append(TemperatureSample(timestamp: Date(), temperatureC: temperatureC))

        let overflow = temperatureSamples.count - displayedTemperatureSampleLimit
        if overflow > 0 {
            temperatureSamples.removeFirst(overflow)
        }
    }

    private func logRawPayload(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else {
            appendMessage("Rx: <non-UTF8 payload \(data.count) bytes>")
            return
        }

        rawLogBuffer.append(chunk)

        while let newlineRange = rawLogBuffer.range(of: "\n") {
            let line = String(rawLogBuffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            rawLogBuffer.removeSubrange(..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            appendMessage("Rx: \(line)")
        }
    }

    private func appendMessage(_ message: String) {
        logEntries.append(DeviceLogEntry(timestamp: Date(), message: message))
        if logEntries.count > logEntryLimit {
            logEntries.removeFirst(logEntries.count - logEntryLimit)
        }
    }

    private func analyzePeriod(samples: [PPGSample], channel: PPGChannel) -> PeriodAnalysis {
        guard samples.count >= 60 else {
            return PeriodAnalysis(kind: .collecting("Collecting"), periodMs: nil, bpm: nil)
        }

        let values = samples.map { Double($0.value(for: channel)) }
        guard let minValue = values.min(), let maxValue = values.max() else {
            return .collecting
        }

        let amplitude = maxValue - minValue
        if amplitude < 20 {
            return PeriodAnalysis(kind: .collecting("Low signal"), periodMs: nil, bpm: nil)
        }

        let smoothed = values.enumerated().map { index, value in
            let previous = values[max(0, index - 1)]
            let next = values[min(values.count - 1, index + 1)]
            return (previous + value + next) / 3.0
        }

        let mean = smoothed.reduce(0.0, +) / Double(smoothed.count)
        let threshold = mean + amplitude * 0.12
        var peaks: [(timeMs: Double, value: Double)] = []

        for index in 1..<(smoothed.count - 1) {
            guard
                smoothed[index] > threshold,
                smoothed[index] > smoothed[index - 1],
                smoothed[index] >= smoothed[index + 1]
            else {
                continue
            }

            let timeMs = samples[index].timestamp.timeIntervalSinceReferenceDate * 1000.0
            let peak = (timeMs: timeMs, value: smoothed[index])

            if let last = peaks.last, peak.timeMs - last.timeMs < 150.0 {
                if peak.value > last.value {
                    peaks[peaks.count - 1] = peak
                }
            } else {
                peaks.append(peak)
            }
        }

        guard peaks.count >= 3 else {
            return PeriodAnalysis(kind: .collecting("Few peaks"), periodMs: nil, bpm: nil)
        }

        let periods = (1..<peaks.count).compactMap { index -> Double? in
            let period = peaks[index].timeMs - peaks[index - 1].timeMs
            return period >= 150.0 && period <= 2_500.0 ? period : nil
        }

        guard periods.count >= 2 else {
            return PeriodAnalysis(kind: .collecting("Few peaks"), periodMs: nil, bpm: nil)
        }

        let period = median(periods)
        let variation = median(periods.map { abs($0 - period) }) / period
        let bpm = Int((60_000.0 / period).rounded())
        let physiologicalPeriod = period >= ppgMinPeriodMs && period <= ppgMaxPeriodMs
        let stablePeriod = variation <= periodVariationLimit
        let kind: SignalKind = physiologicalPeriod && stablePeriod ? .ppg : .noise

        return PeriodAnalysis(kind: kind, periodMs: Int(period.rounded()), bpm: bpm)
    }

    private func median(_ values: [Double]) -> Double {
        let sortedValues = values.sorted()
        let middle = sortedValues.count / 2

        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2.0
        }

        return sortedValues[middle]
    }

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

