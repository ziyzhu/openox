import CoreBluetooth
import Foundation
import UIKit

@MainActor
final class BluetoothProvider: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated private enum Reply: Equatable, Sendable {
        case power
        case scan
        case connect(UUID)
        case disconnect(UUID)
        case services(UUID)
        case characteristics(ObjectIdentifier)
        case descriptors(ObjectIdentifier)
        case read(ObjectIdentifier)
        case write(ObjectIdentifier)
        case notify(ObjectIdentifier)
        case writable(UUID)
    }

    private let sessionID = UUID()
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var advertisements: [UUID: JSONValue] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var descriptors: [String: CBDescriptor] = [:]
    private var events = BluetoothData.EventBuffer()
    private let request = BluetoothRequest<Reply>()
    private var activeDeviceID: UUID?
    private var invocation: UUID?
    private var idleTimeout: Task<Void, Never>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    static var permissionState: NativePermissionState {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func requestPermission() async {
        let provider = BluetoothProvider()
        defer { provider.close() }
        try? await provider.powerOn()
    }

    @objc private func backgrounded() {
        close()
    }

    func close() {
        reset(error: BluetoothData.Failure("sessionClosed", "The session ended. Scan and connect again."))
        events.clear()
    }

    private func reset(error: Error) {
        let hadSession = central != nil || request.reply != nil
        idleTimeout?.cancel()
        idleTimeout = nil
        central?.stopScan()
        central?.delegate = nil
        for peripheral in peripherals.values {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        central = nil
        peripherals.removeAll()
        advertisements.removeAll()
        characteristics.removeAll()
        descriptors.removeAll()
        request.cancel(error)
        if hadSession { Log.service.info("bluetooth.session closed session=\(sessionID)") }
    }

    func invoke(_ action: String, fields: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        if action == "status" { return status() }
        guard invocation == nil else { throw BluetoothData.Failure("busy", "Wait for the current Bluetooth action to finish.") }
        guard UIApplication.shared.applicationState == .active else {
            throw BluetoothData.Failure("background", "Open Ox to use Bluetooth. This service runs in the foreground.")
        }
        let id = UUID()
        invocation = id
        idleTimeout?.cancel()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard self?.invocation == id else { return }
            self?.reset(error: BluetoothData.Failure("timeout", "Action timed out. Scan and connect again."))
        }
        defer {
            deadline.cancel()
            invocation = nil
            activeDeviceID = nil
            idleTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.close()
            }
        }
        Log.service.info("bluetooth.action start session=\(sessionID) request=\(id) action=\(action)")
        return try await withTaskCancellationHandler {
            do {
                let result = try await perform(action, fields: fields)
                try Task.checkCancellation()
                Log.service.info("bluetooth.action done session=\(sessionID) request=\(id) action=\(action) device=\(activeDeviceID?.uuidString ?? "none") discovered=\(advertisements.count) attributes=\(characteristics.count)")
                return result
            } catch {
                if Task.isCancelled { reset(error: CancellationError()) }
                let code = (error as? BluetoothData.Failure)?.code ?? String((error as NSError).code)
                Log.service.warning("bluetooth.action failed session=\(sessionID) request=\(id) action=\(action) code=\(code)")
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.invocation == id else { return }
                self?.reset(error: CancellationError())
            }
        }
    }

    private func status() -> JSONValue {
        let authorization: String = switch CBManager.authorization {
        case .allowedAlways: "granted"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        let state: String = switch central?.state {
        case .poweredOn: "poweredOn"
        case .poweredOff: "poweredOff"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .resetting: "resetting"
        default: "unknown"
        }
        return .object([
            "authorization": .string(authorization), "state": .string(state),
            "connectedDeviceIDs": .array(peripherals.values.filter { $0.state == .connected }.map { $0.identifier.uuidString }.sorted().map(JSONValue.string)),
            "foregroundOnly": .bool(true), "idleTimeoutSeconds": .int(120),
        ])
    }

    private func perform(_ action: String, fields: [String: JSONValue]) async throws -> JSONValue {
        if action == "events" {
            let cursor = fields["after"]?.intValue ?? 0
            guard (0...events.sequence).contains(cursor) else { throw BluetoothData.Failure("invalidCursor", "Use zero or the previous nextCursor from this chat session.") }
            return .object([
                "events": try ServiceOperations.encodeToJSON(events.entries.filter { $0.sequence > cursor }),
                "nextCursor": .int(events.sequence), "dropped": .int(events.dropped(after: cursor)),
            ])
        }
        try await powerOn()
        switch action {
        case "scan":
            let duration = fields["durationSeconds"]?.intValue ?? 5
            guard (1...15).contains(duration) else { throw BluetoothData.Failure("invalidDuration", "Scan for 1–15 seconds.") }
            let uuids = try fields["serviceUUIDs"]?.arrayValue?.map { value -> CBUUID in
                guard let string = value.stringValue,
                      string.range(of: #"^(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$"#, options: .regularExpression) != nil else {
                    throw BluetoothData.Failure("invalidUUID", "Use a 16-bit, 32-bit, or canonical 128-bit Bluetooth UUID.")
                }
                return CBUUID(string: string)
            }
            guard (uuids?.count ?? 0) <= 32 else { throw BluetoothData.Failure("filterLimit", "Use at most 32 service UUID filters.") }
            advertisements.removeAll()
            peripherals = peripherals.filter { $0.value.state != .disconnected }
            defer { central?.stopScan() }
            try await wait(for: .scan, seconds: duration) {
                central?.scanForPeripherals(withServices: uuids?.isEmpty == false ? uuids : nil)
            }
            return .object(["devices": .array(advertisements.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value))])
        case "connect":
            let peripheral = try device(fields)
            if peripheral.state != .connected {
                guard peripherals.values.filter({ $0.state == .connected }).count < 4 else { throw BluetoothData.Failure("connectionLimit", "Disconnect a device before connecting another. Maximum four.") }
                peripheral.delegate = self
                try await wait(for: .connect(peripheral.identifier)) { central?.connect(peripheral) }
            }
            return .object(["deviceID": .string(peripheral.identifier.uuidString), "connected": .bool(true)])
        case "disconnect":
            let peripheral = try device(fields)
            if peripheral.state != .disconnected {
                try await wait(for: .disconnect(peripheral.identifier)) { central?.cancelPeripheralConnection(peripheral) }
            }
            invalidate(peripheral)
            return .object(["deviceID": .string(peripheral.identifier.uuidString), "connected": .bool(false)])
        case "inspect":
            return try await inspect(try device(fields, connected: true))
        case "read":
            let id = try required("attributeID", fields)
            if let descriptor = descriptors[id] {
                guard let peripheral = descriptor.characteristic?.service?.peripheral, peripheral.state == .connected else { throw stale() }
                activeDeviceID = peripheral.identifier
                try await wait(for: .read(ObjectIdentifier(descriptor))) { peripheral.readValue(for: descriptor) }
                return value(id: id, uuid: descriptor.uuid, raw: descriptor.value)
            }
            let characteristic = try characteristic(id)
            guard characteristic.properties.contains(.read) else { throw BluetoothData.Failure("notReadable", "This characteristic does not support reads.") }
            guard !characteristic.isNotifying else { throw BluetoothData.Failure("subscribed", "Read events while subscribed, or unsubscribe before reading.") }
            try await wait(for: .read(ObjectIdentifier(characteristic))) { characteristic.service?.peripheral?.readValue(for: characteristic) }
            return value(id: id, uuid: characteristic.uuid, raw: characteristic.value)
        case "write":
            let characteristic = try characteristic(try required("characteristicID", fields))
            guard let peripheral = characteristic.service?.peripheral else { throw stale() }
            let data = try BluetoothData.bytes(hex: try required("valueHex", fields))
            let mode = fields["mode"]?.stringValue ?? "withResponse"
            guard ["withResponse", "withoutResponse"].contains(mode) else { throw BluetoothData.Failure("invalidMode", "Use withResponse or withoutResponse.") }
            let type: CBCharacteristicWriteType = mode == "withResponse" ? .withResponse : .withoutResponse
            guard characteristic.properties.contains(type == .withResponse ? .write : .writeWithoutResponse) else { throw BluetoothData.Failure("notWritable", "The characteristic does not support this write mode.") }
            let maximum = peripheral.maximumWriteValueLength(for: type)
            guard data.count <= maximum else { throw BluetoothData.Failure("writeTooLarge", "Maximum write length is \(maximum) bytes. Protocol-specific framing is required for larger messages.") }
            if type == .withResponse {
                try await wait(for: .write(ObjectIdentifier(characteristic))) { peripheral.writeValue(data, for: characteristic, type: type) }
            } else {
                if !peripheral.canSendWriteWithoutResponse {
                    try await wait(for: .writable(peripheral.identifier)) {}
                }
                peripheral.writeValue(data, for: characteristic, type: type)
            }
            return .object(["bytes": .int(data.count), "delivery": .string(type == .withResponse ? "acknowledged" : "queued")])
        case "subscribe", "unsubscribe":
            let characteristic = try characteristic(try required("characteristicID", fields))
            guard !characteristic.properties.intersection([.notify, .indicate]).isEmpty else { throw BluetoothData.Failure("notNotifiable", "This characteristic does not support notifications or indications.") }
            let enabled = action == "subscribe"
            if characteristic.isNotifying != enabled {
                try await wait(for: .notify(ObjectIdentifier(characteristic))) { characteristic.service?.peripheral?.setNotifyValue(enabled, for: characteristic) }
            }
            return .object(["subscribed": .bool(characteristic.isNotifying)])
        default:
            throw BluetoothData.Failure("unknownAction", "Unknown Bluetooth action.")
        }
    }

    private func powerOn() async throws {
        try Task.checkCancellation()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        switch central?.state {
        case .poweredOn: return
        case .poweredOff: throw BluetoothData.Failure("poweredOff", "Turn on Bluetooth in Settings, then try again.")
        case .unsupported: throw BluetoothData.Failure("unsupported", "Bluetooth is unavailable on this device. Use a physical iPhone for radio operations.")
        case .unauthorized: throw BluetoothData.Failure("unauthorized", "Allow Bluetooth for Ox in Settings.")
        default: try await wait(for: .power, seconds: 30) {}
        }
    }

    private func wait(for reply: Reply, seconds: Int = 15, start: () -> Void) async throws {
        try await request.wait(for: reply, timeout: .seconds(seconds), expired: { [weak self] in
            guard let self else { return }
            if reply == .scan { complete(reply) }
            else { reset(error: BluetoothData.Failure("timeout", "Bluetooth operation timed out. Scan and connect again.")) }
        }, start: start)
    }

    private func complete(_ reply: Reply, error: Error? = nil) {
        request.complete(reply, error: error)
    }

    private func device(_ fields: [String: JSONValue], connected: Bool = false) throws -> CBPeripheral {
        guard let id = UUID(uuidString: try required("deviceID", fields)), let peripheral = peripherals[id] else { throw stale() }
        guard !connected || peripheral.state == .connected else { throw stale() }
        activeDeviceID = peripheral.identifier
        return peripheral
    }

    private func characteristic(_ id: String) throws -> CBCharacteristic {
        guard let characteristic = characteristics[id], characteristic.service?.peripheral?.state == .connected else { throw stale() }
        activeDeviceID = characteristic.service?.peripheral?.identifier
        return characteristic
    }

    private func required(_ key: String, _ fields: [String: JSONValue]) throws -> String {
        guard let value = fields[key]?.stringValue else { throw BluetoothData.Failure("missingArgument", "Missing \(key).") }
        return value
    }

    private func stale() -> BluetoothData.Failure {
        BluetoothData.Failure("staleHandle", "Device or attribute is unavailable in this chat. Scan, connect, and inspect again.")
    }

    private func invalidate(_ peripheral: CBPeripheral) {
        characteristics = characteristics.filter { $0.value.service?.peripheral !== peripheral }
        descriptors = descriptors.filter { $0.value.characteristic?.service?.peripheral !== peripheral }
    }

    private func inspect(_ peripheral: CBPeripheral) async throws -> JSONValue {
        try await wait(for: .services(peripheral.identifier)) { peripheral.discoverServices(nil) }
        var services: [JSONValue] = []
        guard (peripheral.services?.count ?? 0) <= 64 else { throw BluetoothData.Failure("discoveryLimit", "Device exposes more than 64 services.") }
        for service in peripheral.services ?? [] {
            try await wait(for: .characteristics(ObjectIdentifier(service))) { peripheral.discoverCharacteristics(nil, for: service) }
            var attributes: [JSONValue] = []
            guard (service.characteristics?.count ?? 0) <= 128 else { throw BluetoothData.Failure("discoveryLimit", "Service exposes more than 128 characteristics.") }
            for characteristic in service.characteristics ?? [] {
                let id = characteristics.first { $0.value === characteristic }?.key ?? UUID().uuidString
                guard characteristics[id] != nil || characteristics.count < 512 else { throw BluetoothData.Failure("discoveryLimit", "Session contains more than 512 characteristics. Disconnect unused devices.") }
                characteristics[id] = characteristic
                try await wait(for: .descriptors(ObjectIdentifier(characteristic))) { peripheral.discoverDescriptors(for: characteristic) }
                guard (characteristic.descriptors?.count ?? 0) <= 32 else { throw BluetoothData.Failure("discoveryLimit", "Characteristic exposes more than 32 descriptors.") }
                let descriptorList: [JSONValue] = try (characteristic.descriptors ?? []).map { descriptor in
                    let descriptorID = descriptors.first { $0.value === descriptor }?.key ?? UUID().uuidString
                    guard descriptors[descriptorID] != nil || descriptors.count < 1_024 else { throw BluetoothData.Failure("discoveryLimit", "Session contains more than 1024 descriptors. Disconnect unused devices.") }
                    descriptors[descriptorID] = descriptor
                    return .object(["id": .string(descriptorID), "uuid": .string(descriptor.uuid.uuidString)])
                }
                let properties: [(CBCharacteristicProperties, String)] = [(.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeWithoutResponse"), (.notify, "notify"), (.indicate, "indicate"), (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"), (.broadcast, "broadcast")]
                attributes.append(.object([
                    "id": .string(id), "uuid": .string(characteristic.uuid.uuidString),
                    "properties": .array(properties.filter { characteristic.properties.contains($0.0) }.map { .string($0.1) }),
                    "subscribed": .bool(characteristic.isNotifying), "descriptors": .array(descriptorList),
                ]))
            }
            services.append(.object(["uuid": .string(service.uuid.uuidString), "primary": .bool(service.isPrimary), "characteristics": .array(attributes)]))
        }
        return .object([
            "deviceID": .string(peripheral.identifier.uuidString), "services": .array(services),
            "maximumWriteWithResponse": .int(peripheral.maximumWriteValueLength(for: .withResponse)),
            "maximumWriteWithoutResponse": .int(peripheral.maximumWriteValueLength(for: .withoutResponse)),
        ])
    }

    private func value(id: String, uuid: CBUUID, raw: Any?) -> JSONValue {
        let data = raw as? Data
        let battery = uuid == CBUUID(string: "2A19") && data?.count == 1
            ? data?.first.flatMap { $0 <= 100 ? Int($0) : nil } : nil
        let textUUIDs = ["2A24", "2A25", "2A26", "2A27", "2A28", "2A29", "2A00"]
        let text = (raw as? String) ?? (textUUIDs.contains(uuid.uuidString) ? data.flatMap { String(data: $0, encoding: .utf8) } : nil)
        return .object([
            "attributeID": .string(id), "uuid": .string(uuid.uuidString),
            "valueHex": data.map { .string(BluetoothData.hex($0)) } ?? .null,
            "text": text.map(JSONValue.string) ?? .null,
            "number": battery.map(JSONValue.int) ?? (raw as? NSNumber).map { .double($0.doubleValue) } ?? .null,
            "unit": battery != nil ? .string("percent") : .null,
        ])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        Log.service.info("bluetooth.state session=\(sessionID) state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        if central.state == .poweredOn { complete(.power) }
        else if central.state != .unknown {
            let failure: BluetoothData.Failure = switch central.state {
            case .poweredOff: .init("poweredOff", "Turn on Bluetooth in Settings, then try again.")
            case .unsupported: .init("unsupported", "Bluetooth is unavailable here. Use a physical iPhone for radio operations.")
            case .unauthorized: .init("unauthorized", "Allow Bluetooth for Ox in Settings.")
            default: .init("resetting", "Bluetooth is resetting. Scan and connect again.")
            }
            request.cancel(failure)
            for peripheral in peripherals.values { peripheral.delegate = nil }
            peripherals.removeAll()
            advertisements.removeAll()
            characteristics.removeAll()
            descriptors.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, request.reply == .scan, advertisements.count < 100 || advertisements[peripheral.identifier] != nil else { return }
        peripherals[peripheral.identifier] = peripheral
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        advertisements[peripheral.identifier] = .object([
            "deviceID": .string(peripheral.identifier.uuidString),
            "name": ((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name).map(JSONValue.string) ?? .null,
            "rssi": RSSI.intValue == 127 ? .null : .int(RSSI.intValue),
            "connectable": (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber).map { .bool($0.boolValue) } ?? .null,
            "serviceUUIDs": .array((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { .string($0.uuidString) }),
            "manufacturerDataHex": (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { .string(BluetoothData.hex($0)) } ?? .null,
            "serviceData": .array(serviceData.sorted { $0.key.uuidString < $1.key.uuidString }.map { .object(["uuid": .string($0.key.uuidString), "valueHex": .string(BluetoothData.hex($0.value))]) }),
        ])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        complete(.connect(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { return }
        complete(.connect(peripheral.identifier), error: error ?? BluetoothData.Failure("connectionFailed", "Could not connect to device."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { return }
        invalidate(peripheral)
        events.append(kind: "disconnected", deviceID: peripheral.identifier.uuidString, errorCode: error.map { String(($0 as NSError).code) })
        if request.reply == .disconnect(peripheral.identifier) { complete(.disconnect(peripheral.identifier), error: error) }
        else if activeDeviceID == peripheral.identifier { reset(error: BluetoothData.Failure("disconnected", "Device disconnected. Scan, connect, and inspect again.")) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        complete(.services(peripheral.identifier), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        complete(.characteristics(ObjectIdentifier(service)), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        complete(.descriptors(ObjectIdentifier(characteristic)), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.isNotifying, let id = characteristics.first(where: { $0.value === characteristic })?.key {
            events.append(kind: error == nil ? "value" : "error", deviceID: peripheral.identifier.uuidString, characteristicID: id, data: error == nil ? characteristic.value : nil, errorCode: error.map { String(($0 as NSError).code) })
        }
        complete(.read(ObjectIdentifier(characteristic)), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        complete(.read(ObjectIdentifier(descriptor)), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        complete(.write(ObjectIdentifier(characteristic)), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        complete(.notify(ObjectIdentifier(characteristic)), error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        complete(.writable(peripheral.identifier))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        invalidate(peripheral)
        events.append(kind: "servicesChanged", deviceID: peripheral.identifier.uuidString)
        if activeDeviceID == peripheral.identifier { reset(error: stale()) }
        else { central?.cancelPeripheralConnection(peripheral) }
    }
}
