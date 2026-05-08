import Foundation

struct PPGSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let streamTimeMs: Int
    let red: Int
    let ir: Int
    let green: Int

    func value(for channel: PPGChannel) -> Int {
        switch channel {
        case .red:
            return red
        case .ir:
            return ir
        case .green:
            return green
        }
    }
}

struct PPGPacketSample {
    let timeMs: Int
    let red: Int
    let ir: Int
    let green: Int
}

struct TemperatureSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let temperatureC: Double
}

struct DeviceLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    var renderedText: String {
        "[\(Self.timestampFormatter.string(from: timestamp))] \(message)"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

enum PPGChannel: CaseIterable, Identifiable {
    case red
    case ir
    case green

    var id: String {
        label
    }

    var label: String {
        switch self {
        case .red:
            return "Red"
        case .ir:
            return "IR"
        case .green:
            return "Green"
        }
    }
}

enum SensorHealth: String {
    case normal = "Ready"
    case error = "No Sensor"
    case unknown = "Unknown"

    var description: String {
        rawValue
    }
}

enum SignalKind: Equatable {
    case collecting(String)
    case ppg
    case noise
}

struct PeriodAnalysis: Equatable {
    let kind: SignalKind
    let periodMs: Int?
    let bpm: Int?

    var statusText: String {
        switch kind {
        case .collecting(let reason):
            return reason
        case .ppg:
            guard let bpm else { return "PPG" }
            return "PPG / \(bpm) BPM"
        case .noise:
            guard let bpm else { return "Noise" }
            return "Noise / \(bpm) BPM"
        }
    }

    var periodText: String {
        guard let periodMs else { return "--" }
        return "\(periodMs) ms"
    }

    static let collecting = PeriodAnalysis(kind: .collecting("Collecting"), periodMs: nil, bpm: nil)
}

