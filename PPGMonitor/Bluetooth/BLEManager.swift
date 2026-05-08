import CoreBluetooth
import Foundation

enum BLEConnectionState: Equatable {
    case idle
    case bluetoothUnavailable(String)
    case unauthorized
    case scanning
    case connecting(String)
    case connected(String)

    var title: String {
        switch self {
        case .idle:
            return "Not Connected"
        case .bluetoothUnavailable(let reason):
            return "Bluetooth Unavailable: \(reason)"
        case .unauthorized:
            return "Bluetooth Permission Needed"
        case .scanning:
            return "Scanning for BLE Devices..."
        case .connecting(let name):
            return "Connecting to \(name)..."
        case .connected(let name):
            return "Connected to \(name)"
        }
    }
}

struct BLEDiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let identifierSuffix: String
    let rssi: Int

    var connectionLabel: String {
        "\(name) • \(identifierSuffix)"
    }

    var detailText: String {
        "ID \(identifierSuffix) • RSSI \(rssi) dBm"
    }
}

final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStateChange: ((BLEConnectionState) -> Void)?
    var onDiscoveredDevicesChange: (([BLEDiscoveredDevice]) -> Void)?
    var onPayload: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private var centralManager: CBCentralManager?
    private var discoveredPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    private var isScanning = false
    private var shouldStartScanWhenReady = false
    private var discoveredPeripheralsByID: [UUID: CBPeripheral] = [:]
    private var discoveredDevices: [BLEDiscoveredDevice] = []

    func start() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func startScan() {
        shouldStartScanWhenReady = true
        start()
        handleCentralState()
    }

    func stopScan() {
        shouldStartScanWhenReady = false

        guard let centralManager else { return }

        if isScanning {
            isScanning = false
            centralManager.stopScan()
        }
    }

    func connect(to deviceID: UUID) {
        start()

        guard let centralManager else { return }
        guard centralManager.state == .poweredOn else {
            handleCentralState()
            return
        }

        guard let peripheral = discoveredPeripheralsByID[deviceID] else {
            onLog?("The selected device is no longer available. Please scan again.")
            return
        }

        if let currentPeripheral = discoveredPeripheral,
           currentPeripheral.identifier != peripheral.identifier,
           currentPeripheral.state == .connected || currentPeripheral.state == .connecting {
            onLog?("Disconnect the current device before connecting to another board.")
            return
        }

        if isScanning {
            isScanning = false
            centralManager.stopScan()
        }

        shouldStartScanWhenReady = false
        discoveredPeripheral = peripheral
        peripheral.delegate = self

        let label = connectionLabel(for: peripheral)
        updateState(.connecting(label))
        onLog?("Connecting to \(label)...")
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let centralManager, let peripheral = discoveredPeripheral else {
            updateState(.idle)
            return
        }

        centralManager.cancelPeripheralConnection(peripheral)
    }

    func sendCommand(_ command: String) {
        guard
            let peripheral = discoveredPeripheral,
            let rxCharacteristic,
            let data = command.data(using: .utf8)
        else {
            onLog?("Tx failed: BLE link is not ready.")
            return
        }

        let writeType: CBCharacteristicWriteType = rxCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rxCharacteristic, type: writeType)
        onLog?("Tx: \(command)")
    }

    private func handleCentralState() {
        guard let centralManager else { return }

        switch centralManager.state {
        case .poweredOn:
            if shouldStartScanWhenReady {
                scanForPeripheral()
            } else if discoveredPeripheral == nil {
                updateState(.idle)
            }
        case .unauthorized:
            shouldStartScanWhenReady = false
            clearDiscoveredDevices()
            updateState(.unauthorized)
        case .unsupported:
            shouldStartScanWhenReady = false
            clearDiscoveredDevices()
            updateState(.bluetoothUnavailable("This iPhone does not support BLE."))
        case .poweredOff:
            shouldStartScanWhenReady = false
            clearDiscoveredDevices()
            updateState(.bluetoothUnavailable("Bluetooth is turned off."))
        case .resetting:
            shouldStartScanWhenReady = false
            clearDiscoveredDevices()
            updateState(.bluetoothUnavailable("Bluetooth is resetting."))
        case .unknown:
            clearDiscoveredDevices()
            updateState(.bluetoothUnavailable("Bluetooth state is unknown."))
        @unknown default:
            clearDiscoveredDevices()
            updateState(.bluetoothUnavailable("Bluetooth entered an unexpected state."))
        }
    }

    private func scanForPeripheral() {
        guard let centralManager else { return }
        guard centralManager.state == .poweredOn else {
            handleCentralState()
            return
        }

        if let peripheral = discoveredPeripheral, peripheral.state == .connected || peripheral.state == .connecting {
            onLog?("Disconnect the current device before scanning for another board.")
            return
        }

        if isScanning {
            centralManager.stopScan()
        }

        discoveredPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        isScanning = true
        clearDiscoveredDevices()

        updateState(.scanning)
        onLog?("Scanning for compatible BLE peripherals...")
        centralManager.scanForPeripherals(
            withServices: [NUSConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func updateState(_ state: BLEConnectionState) {
        DispatchQueue.main.async { [onStateChange] in
            onStateChange?(state)
        }
    }

    private func publishDiscoveredDevices() {
        let snapshot = discoveredDevices
        DispatchQueue.main.async { [onDiscoveredDevicesChange] in
            onDiscoveredDevicesChange?(snapshot)
        }
    }

    private func clearDiscoveredDevices() {
        discoveredPeripheralsByID.removeAll()
        discoveredDevices.removeAll()
        publishDiscoveredDevices()
    }

    private func shortIdentifier(for identifier: UUID) -> String {
        String(identifier.uuidString.replacingOccurrences(of: "-", with: "").suffix(6)).uppercased()
    }

    private func resolvedName(for peripheral: CBPeripheral, advertisedName: String? = nil) -> String {
        let candidate = (advertisedName ?? peripheral.name ?? NUSConstants.targetName).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? NUSConstants.targetName : candidate
    }

    private func connectionLabel(for peripheral: CBPeripheral, advertisedName: String? = nil) -> String {
        "\(resolvedName(for: peripheral, advertisedName: advertisedName)) • \(shortIdentifier(for: peripheral.identifier))"
    }

    private func shouldIncludePeripheral(named advertisedName: String, advertisementData: [String: Any]) -> Bool {
        if advertisedName.localizedCaseInsensitiveContains(NUSConstants.targetName) {
            return true
        }

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return advertisedServices.contains(NUSConstants.serviceUUID)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleCentralState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"

        guard shouldIncludePeripheral(named: advertisedName, advertisementData: advertisementData) else {
            return
        }

        let device = BLEDiscoveredDevice(
            id: peripheral.identifier,
            name: resolvedName(for: peripheral, advertisedName: advertisedName),
            identifierSuffix: shortIdentifier(for: peripheral.identifier),
            rssi: RSSI.intValue
        )

        discoveredPeripheralsByID[device.id] = peripheral

        if let existingIndex = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[existingIndex] = device
        } else {
            discoveredDevices.append(device)
            onLog?("Found \(device.connectionLabel) (\(RSSI) dBm).")
        }

        discoveredDevices.sort {
            if $0.name == $1.name {
                return $0.rssi > $1.rssi
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        publishDiscoveredDevices()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let label = connectionLabel(for: peripheral)
        shouldStartScanWhenReady = false
        clearDiscoveredDevices()
        updateState(.connected(label))
        onLog?("Connected to \(label). Discovering services...")
        peripheral.discoverServices([NUSConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Unknown error"
        onLog?("Failed to connect: \(message)")
        updateState(.idle)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Connection closed."
        onLog?("Disconnected: \(message)")
        discoveredPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        updateState(.idle)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onLog?("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == NUSConstants.serviceUUID }) else {
            onLog?("NUS service was not found on the peripheral.")
            return
        }

        peripheral.discoverCharacteristics([NUSConstants.rxCharacteristicUUID, NUSConstants.txCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            onLog?("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            onLog?("No characteristics were returned for the NUS service.")
            return
        }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case NUSConstants.rxCharacteristicUUID:
                rxCharacteristic = characteristic
            case NUSConstants.txCharacteristicUUID:
                txCharacteristic = characteristic
            default:
                break
            }
        }

        guard let txCharacteristic else {
            onLog?("NUS TX characteristic was not found.")
            return
        }

        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onLog?("Enabling notifications failed: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == NUSConstants.txCharacteristicUUID else { return }
        onLog?("BLE link is ready. You can start streaming PPG data.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onLog?("Receive error: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == NUSConstants.txCharacteristicUUID, let data = characteristic.value else {
            return
        }

        DispatchQueue.main.async { [onPayload] in
            onPayload?(data)
        }
    }
}

