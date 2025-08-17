import Foundation
import CoreBluetooth
import Cocoa

// MARK: - Delegate Protocol
protocol BluetoothDeviceManagerDelegate: AnyObject {
    func didConnectToDevice(data: Data)
    func didDisconnectFromDevice(data: Data)
    func didUpdatePageChange(data: Data)
}

// MARK: - Constants
private enum BluetoothConstants {
    static let deviceName = "Timeular Tracker"
    static let orientationCharacteristicUUID = CBUUID(string: "c7e70012-c847-11e6-8175-8c89a55d403c")
    static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    
    // Intelligent backoff intervals (seconds)
    static let initialReconnectInterval: TimeInterval = 5.0
    static let shortTermInterval: TimeInterval = 30.0
    static let mediumTermInterval: TimeInterval = 120.0  // 2 minutes
    static let longTermInterval: TimeInterval = 300.0   // 5 minutes
    static let maxInterval: TimeInterval = 900.0        // 15 minutes
    
    // Thresholds for backoff strategy
    static let shortTermAttempts = 12    // First minute (5s * 12)
    static let mediumTermAttempts = 24   // Next 30 minutes (30s * 24 + previous)
    static let longTermAttempts = 48     // Next 2 hours (2min * 48 + previous)
}

// MARK: - BluetoothDeviceManager
final class BluetoothDeviceManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    weak var delegate: BluetoothDeviceManagerDelegate?
    private var reconnectTimer: Timer?
    
    // Intelligent reconnection management
    private var reconnectAttempts: Int = 0
    private var lastDisconnectionTime: Date?
    private var isBackgroundScanning: Bool = false

    // MARK: - Lifecycle
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .utility))
    }
    
    deinit {
        cleanup()
    }

    // MARK: - CBCentralManagerDelegate
    @objc func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            NSLog("Bluetooth powered on")
            attemptConnectionOrScan()
        case .poweredOff:
            NSLog("Bluetooth is powered off")
            stopReconnectTimer()
        case .unauthorized:
            NSLog("Bluetooth access denied")
        case .unsupported:
            NSLog("Bluetooth not supported")
        default:
            NSLog("Bluetooth state: \(central.state.rawValue)")
        }
    }

    // MARK: - Public Interface
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            NSLog("Cannot scan: Bluetooth not powered on")
            return
        }
        
        NSLog("Starting device scan...")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        NSLog("Stopping device scan")
        centralManager.stopScan()
    }
    
    func disconnectFromDevice() {
        guard let peripheral = peripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func attemptReconnection() {
        guard centralManager.state == .poweredOn else { return }
        attemptConnectionOrScan()
    }
    
    // MARK: - Private Methods
    private func attemptConnectionOrScan() {
        if let peripheral = peripheral {
            NSLog("Attempting to reconnect to known device")
            centralManager.connect(peripheral, options: nil)
        } else {
            startScanning()
        }
    }

    @objc func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == BluetoothConstants.deviceName else { return }
        
        NSLog("Found device: \(peripheral.name ?? "Unknown")")
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        centralManager.connect(peripheral, options: nil)
        stopScanning()
    }

    @objc func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("Connected to device: \(peripheral.name ?? "Unknown") after \(reconnectAttempts) attempts")
        resetReconnectionState()
        delegate?.didConnectToDevice(data: Data())
        peripheral.discoverServices(nil)
    }

    @objc func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            NSLog("Disconnected from device with error: \(error.localizedDescription)")
        } else {
            NSLog("Disconnected from device: \(peripheral.name ?? "Unknown")")
        }
        
        lastDisconnectionTime = Date()
        delegate?.didDisconnectFromDevice(data: Data())
        startReconnectTimer()
    }
    
    @objc func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("Failed to connect to device: \(error?.localizedDescription ?? "Unknown error")")
        startReconnectTimer()
    }

    private func startReconnectTimer() {
        stopReconnectTimer()
        
        let interval = calculateReconnectInterval()
        NSLog("Starting reconnect timer with interval: \(interval)s (attempt #\(reconnectAttempts + 1))")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.executeIntelligentReconnection()
        }
    }
    
    private func calculateReconnectInterval() -> TimeInterval {
        switch reconnectAttempts {
        case 0..<BluetoothConstants.shortTermAttempts:
            return BluetoothConstants.initialReconnectInterval
        case BluetoothConstants.shortTermAttempts..<BluetoothConstants.mediumTermAttempts:
            return BluetoothConstants.shortTermInterval
        case BluetoothConstants.mediumTermAttempts..<BluetoothConstants.longTermAttempts:
            return BluetoothConstants.mediumTermInterval
        case BluetoothConstants.longTermAttempts..<(BluetoothConstants.longTermAttempts + 24):
            return BluetoothConstants.longTermInterval
        default:
            return BluetoothConstants.maxInterval
        }
    }
    
    private func executeIntelligentReconnection() {
        reconnectAttempts += 1
        
        // For long-term disconnections (>1 hour), use background scanning
        if reconnectAttempts > BluetoothConstants.longTermAttempts && !isBackgroundScanning {
            startEfficientBackgroundScanning()
        } else {
            attemptConnectionOrScan()
            
            // Schedule next attempt only if not connected
            if peripheral?.state != .connected {
                startReconnectTimer()
            }
        }
    }
    
    private func startEfficientBackgroundScanning() {
        guard centralManager.state == .poweredOn else { return }
        
        NSLog("Starting efficient background scanning for long-term reconnection")
        isBackgroundScanning = true
        
        // Use background-friendly scanning options
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
            CBCentralManagerScanOptionSolicitedServiceUUIDsKey: []
        ]
        
        centralManager.scanForPeripherals(withServices: nil, options: options)
        
        // Continue with long intervals but less frequent active attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + BluetoothConstants.maxInterval) { [weak self] in
            if self?.isBackgroundScanning == true && self?.peripheral?.state != .connected {
                self?.startReconnectTimer()
            }
        }
    }
    
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        if isBackgroundScanning {
            NSLog("Stopping background scanning")
            centralManager.stopScan()
            isBackgroundScanning = false
        }
    }
    
    private func resetReconnectionState() {
        stopReconnectTimer()
        reconnectAttempts = 0
        lastDisconnectionTime = nil
        
        if isBackgroundScanning {
            NSLog("Connected - stopping background scanning")
            centralManager.stopScan()
            isBackgroundScanning = false
        }
    }
    
    private func cleanup() {
        resetReconnectionState()
        stopScanning()
        
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        delegate = nil
    }

    // MARK: - CBPeripheralDelegate
    @objc func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            NSLog("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    @objc func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            NSLog("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BluetoothConstants.orientationCharacteristicUUID || 
               characteristic.uuid == BluetoothConstants.batteryLevelCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    @objc func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("Error updating characteristic value: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == BluetoothConstants.batteryLevelCharacteristicUUID {
            handleBatteryLevelUpdate(data: data)
        } else if characteristic.uuid == BluetoothConstants.orientationCharacteristicUUID {
            delegate?.didUpdatePageChange(data: data)
        }
    }
    
    private func handleBatteryLevelUpdate(data: Data) {
        let batteryLevel = data.first ?? 0
        let batteryLevelString = "\(batteryLevel)%"
        
        DispatchQueue.main.async {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.updateBatteryLevel(batteryLevelString)
            }
        }
    }
}
