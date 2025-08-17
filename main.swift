import Cocoa
import CoreBluetooth
import UserNotifications

// MARK: - Constants
private enum MenuIndices {
    static let openTimetagger = 0
    static let battery = 1
    static let stopTracking = 3
}

private enum Constants {
    static let timerUpdateInterval: TimeInterval = 1.0
    static let timerItemWidth: CGFloat = 40
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, BluetoothDeviceManagerDelegate, UNUserNotificationCenterDelegate {
    // MARK: - Properties
    private var statusItem: NSStatusItem!
    private var appLogic: AppLogic!
    private var bluetoothManager: BluetoothDeviceManager!
    private var configuration: Configuration!
    private var timer: Timer?
    private var startDate: Date?
    private var sleepNotification: NSObjectProtocol?
    private var isTracking: Bool = false
    
    // MARK: - Lifecycle
    deinit {
        cleanup()
    }

    // MARK: - NSApplicationDelegate
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusBar()
        requestNotificationAuthorization()
        loadConfiguration()
        initializeBluetoothManager()
        registerForSleepWakeNotifications()
        
        // Ensure menu state is properly initialized
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        cleanup()
    }

    // MARK: - Configuration
    private func requestConfigurationFromUser() {
        let alert = NSAlert()
        alert.messageText = "Missing Configuration File"
        alert.informativeText = "Please create .time-tagger/config.json and restart the application."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Sleep/Wake Handling
    private func registerForSleepWakeNotifications() {
        sleepNotification = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func handleSleep() {
        stopTimer()
        bluetoothManager.disconnectFromDevice()
        setTrackingState(false)
    }

    @objc private func handleWake() {
        bluetoothManager.attemptReconnection()

        if isTracking, let startDate = startDate {
            startTimer(from: startDate)
        } else {
            resetStatusBarIcon()
        }
        
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
        }
    }

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                NSLog("User denied notification permissions")
            }
        }
    }

    private func loadConfiguration() {
        configuration = Configuration.load()
        if configuration == nil {
            requestConfigurationFromUser()
        } else {
            appLogic = AppLogic(apiKey: configuration.apiKey, timetaggerUrl: configuration.timetaggerUrl, configuration: configuration)
        }
    }

    // MARK: - Status Bar Setup
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        configureStatusBarButton()
        createStatusBarMenu()
    }
    
    private func configureStatusBarButton() {
        guard let button = statusItem.button else { return }
        
        button.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Time Tracker")
        button.action = #selector(showMenu)
        button.target = self
    }
    
    private func createStatusBarMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Open Timetagger", action: #selector(openTimetagger), keyEquivalent: "T"))
        menu.addItem(NSMenuItem(title: "Battery: Loading...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let stopTrackingMenuItem = NSMenuItem(title: "Stop Tracking", action: #selector(stopTracking), keyEquivalent: "S")
        stopTrackingMenuItem.isEnabled = false
        menu.addItem(stopTrackingMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "Q"))
        
        statusItem.menu = menu
    }

    // MARK: - Menu Actions
    @objc private func showMenu() {
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: statusItem.button)
    }
    
    private func updateStopTrackingMenuState() {
        guard let menuItem = statusItem.menu?.item(at: MenuIndices.stopTracking) else {
            NSLog("Error: Cannot find stop tracking menu item")
            return
        }
        
        menuItem.isEnabled = isTracking
        menuItem.action = isTracking ? #selector(stopTracking) : nil
    }

    @objc private func openTimetagger() {
        // TODO: Implement Timetagger opening functionality
        NSLog("Opening Timetagger...")
    }

    @objc private func stopTracking() {
        guard isTracking else {
            NSLog("Cannot stop tracking - tracking is not active")
            return
        }
        
        appLogic.stopTracking()
        stopTimer()
        resetStatusBarIcon()
        setTrackingState(false)
        
        NSLog("Tracking stopped manually by user")
    }

    @objc private func quit() {
        cleanup()
        NSApplication.shared.terminate(self)
    }

    // MARK: - BluetoothDeviceManagerDelegate
    func didConnectToDevice(data: Data) {
        let pageValue = extractPageFromData(data: data)
        
        // Only start tracking if device shows an active page with description
        if pageValue != 0 && !(configuration.pageDescriptions[pageValue]?.isEmpty ?? true) {
            appLogic.startTracking(data: data)
            setTrackingState(true)
        } else {
            setTrackingState(false)
        }
    }

    func didDisconnectFromDevice(data: Data) {
        setTrackingState(false)
    }

    func didUpdatePageChange(data: Data) {
        appLogic.didUpdatePageChange(data: data)
        let pageValue = extractPageFromData(data: data)

        DispatchQueue.main.async {
            if pageValue == 0 || (self.configuration.pageDescriptions[pageValue]?.isEmpty ?? true) {
                self.stopTimer()
                self.resetStatusBarIcon()
                self.setTrackingState(false)
            } else {
                self.stopTimer()
                self.startTimer()
                self.updateTimerUI()
                self.setTrackingState(true)
            }
        }
    }

    // MARK: - Timer Management
    private func startTimer(from date: Date? = nil) {
        guard timer == nil else { return }
        
        startDate = date ?? Date()
        timer = Timer.scheduledTimer(withTimeInterval: Constants.timerUpdateInterval, repeats: true) { [weak self] _ in
            self?.updateTimerUI()
        }
        statusItem.length = Constants.timerItemWidth
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        statusItem.length = NSStatusItem.variableLength
    }

    private func resetStatusBarIcon() {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Time Tracker")
            button.attributedTitle = NSAttributedString(string: " ")
            self.statusItem.length = NSStatusItem.variableLength
        }
    }

    private func updateTimerUI() {
        guard let startDate = startDate else { return }
        
        let elapsedTime = Int(Date().timeIntervalSince(startDate))
        let hours = elapsedTime / 3600
        let minutes = (elapsedTime % 3600) / 60
        let timerString = String(format: "%02d:%02d", hours, minutes)
        
        if let button = statusItem.button {
            button.title = timerString
            button.image = nil
        }
    }

    // MARK: - Public Interface
    func updateBatteryLevel(_ level: String) {
        DispatchQueue.main.async {
            guard let menuItem = self.statusItem.menu?.item(at: MenuIndices.battery) else { return }
            menuItem.title = "Battery: \(level)"
        }
    }

    private func extractPageFromData(data: Data) -> Int {
        return Int(data.first ?? 0)
    }
    
    // MARK: - Helper Methods
    private func initializeBluetoothManager() {
        bluetoothManager = BluetoothDeviceManager()
        bluetoothManager.delegate = self
    }
    
    private func setTrackingState(_ tracking: Bool) {
        isTracking = tracking
        if !tracking {
            startDate = nil
        }
        
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
        }
    }
    
    private func cleanup() {
        // Stop tracking if active
        if isTracking {
            appLogic?.stopTracking()
            isTracking = false
        }
        
        // Clean up timer
        timer?.invalidate()
        timer = nil
        startDate = nil
        
        // Remove notifications
        if let sleepNotification = sleepNotification {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepNotification)
            self.sleepNotification = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        
        // Disconnect Bluetooth
        bluetoothManager?.disconnectFromDevice()
        bluetoothManager?.delegate = nil
        
        // Clean up status item
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
