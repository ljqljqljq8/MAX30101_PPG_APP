import Foundation

enum DeviceEvent {
    case batch(samples: [PPGPacketSample])
    case legacySample(red: Int, ir: Int, green: Int)
    case temperature(Double)
    case streamState(Bool)
    case status(sent: Int, dropped: Int)
    case sensorHealth(SensorHealth, message: String)
    case message(String)
}

struct PPGPacketParser {
    private(set) var buffer = ""
    private let validRawRange = 0...0x3FFFF

    mutating func consume(_ data: Data) -> [DeviceEvent] {
        guard let chunk = String(data: data, encoding: .utf8) else {
            return [.message("Received non-UTF8 BLE payload (\(data.count) bytes).")]
        }

        buffer.append(chunk)

        var events: [DeviceEvent] = []

        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            events.append(contentsOf: parseLine(line))
        }

        return events
    }

    private func parseLine(_ line: String) -> [DeviceEvent] {
        let cleanLine = line
            .filter { character in
                guard let scalar = character.unicodeScalars.first else { return false }
                return scalar.value >= 0x20 && scalar.value <= 0x7E
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanLine.isEmpty else { return [] }

        if let batchRange = cleanLine.range(of: "B:") {
            let payload = String(cleanLine[batchRange.upperBound...])
            let samples = parseBatch(payload)
            if samples.isEmpty {
                return [.message("Ignored malformed PPG packet: \(cleanLine)")]
            }
            return [.batch(samples: samples)]
        }

        if cleanLine.hasPrefix("D:") {
            let payload = String(cleanLine.dropFirst(2))
            if let sample = parseLegacySample(payload) {
                return [.legacySample(red: sample.red, ir: sample.ir, green: sample.green)]
            }
            return [.message("Ignored malformed legacy PPG packet: \(cleanLine)")]
        }

        if cleanLine == "STREAM:ON" {
            return [.streamState(true)]
        }

        if cleanLine == "STREAM:OFF" {
            return [.streamState(false)]
        }

        if cleanLine == "INIT:MAX30101_NOT_FOUND" {
            return [.sensorHealth(.error, message: "MAX30101 was not found on I2C address 0x57.")]
        }

        if cleanLine.hasPrefix("INIT:OK") {
            return [.sensorHealth(.normal, message: cleanLine)]
        }

        if cleanLine == "TEMP:NO_SENSOR" {
            return [.sensorHealth(.error, message: "Temperature query failed because the MAX30101 is not ready.")]
        }

        if cleanLine.hasPrefix("T:") {
            let payload = cleanLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let temperatureC = Double(payload) else {
                return [.message("Ignored malformed temperature packet: \(cleanLine)")]
            }
            return [.temperature(temperatureC)]
        }

        if cleanLine.hasPrefix("STAT:") {
            let payload = cleanLine.dropFirst(5)
            let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard
                parts.count == 2,
                let sent = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                let dropped = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else {
                return [.message("Ignored malformed status packet: \(cleanLine)")]
            }
            return [.status(sent: sent, dropped: dropped)]
        }

        return [.message(cleanLine)]
    }

    private func parseBatch(_ payload: String) -> [PPGPacketSample] {
        payload
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { parseTimedSample(String($0)) }
    }

    private func parseTimedSample(_ payload: String) -> PPGPacketSample? {
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false)

        guard
            parts.count == 4,
            let timeMs = Int(parts[0].trimmingCharacters(in: .whitespaces)),
            let red = parseHexRaw(parts[1]),
            let ir = parseHexRaw(parts[2]),
            let green = parseHexRaw(parts[3])
        else {
            return nil
        }

        return PPGPacketSample(timeMs: timeMs, red: red, ir: ir, green: green)
    }

    private func parseLegacySample(_ payload: String) -> (red: Int, ir: Int, green: Int)? {
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false)

        guard
            parts.count == 3,
            let red = parseHexRaw(parts[0]),
            let ir = parseHexRaw(parts[1]),
            let green = parseHexRaw(parts[2])
        else {
            return nil
        }

        return (red, ir, green)
    }

    private func parseHexRaw(_ value: Substring) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard
            (1...5).contains(text.count),
            let raw = Int(text, radix: 16),
            validRawRange.contains(raw)
        else {
            return nil
        }

        return raw
    }
}

