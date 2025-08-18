import Cocoa
import CoreBluetooth
import UserNotifications

// MARK: - Constants
private enum MenuIndices {
    static let openTimetagger = 0
    static let battery = 1
    static let stopTracking = 3
    static let findTimeCube = 4
    static let forgetTimeCube = 5
}

private enum Constants {
    static let timerUpdateInterval: TimeInterval = 10.0  // 10s - battery friendly
    static let timerItemWidth: CGFloat = 40
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, BluetoothDeviceManagerDelegate, UNUserNotificationCenterDelegate, AppLogicDelegate {
    // MARK: - Properties
    private var statusItem: NSStatusItem!
    private var appLogic: AppLogic!
    private var bluetoothManager: BluetoothDeviceManager!
    private var configuration: Configuration!
    private var timer: Timer?
    private var startDate: Date?
    private var sleepNotification: NSObjectProtocol?
    private var isTracking: Bool = false
    private var currentActivity: String = ""
    private var discoveredDevices: [CBPeripheral] = []
    private var deviceSelectionAlert: NSAlert?
    private var searchingAlert: NSAlert?
    private var isDeviceConnected: Bool = false
    
    // MARK: - Lifecycle
    deinit {
        cleanup()
    }

    // MARK: - NSApplicationDelegate
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set app activation policy to make it more visible to notification system
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusBar()
        requestNotificationAuthorization()
        loadConfiguration()
        initializeBluetoothManager()
        registerForSleepWakeNotifications()
        
        // Ensure menu state is properly initialized
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
            // Device menu state will be updated after Bluetooth manager initializes
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        cleanup()
    }

    // MARK: - Configuration
    private func requestConfigurationFromUser() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Missing Configuration File"
            alert.informativeText = "Please create .time-tagger/config.json and restart the application."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApplication.shared.terminate(self)
        }
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
        NSLog("Computer going to sleep - pausing timer and disconnecting Bluetooth")
        stopTimer()
        bluetoothManager.disconnectFromDevice()
        // Keep tracking state - we'll resume after wake
        NSLog("Sleep preparation complete")
    }

    @objc private func handleWake() {
        NSLog("Computer waking up - restoring connections and timer")
        bluetoothManager.attemptReconnection()

        // Properly restore timer if tracking was active before sleep
        if isTracking, let startDate = startDate {
            NSLog("Restoring timer from sleep - tracking was active")
            startTimer(from: startDate)
            updateTimerUI()
        } else {
            NSLog("No active tracking to restore")
            resetStatusBarIcon()
        }
        
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
        }
        
        NSLog("Wake handling complete")
    }

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NSLog("Set notification center delegate to AppDelegate")
        NSLog("Delegate object: \(String(describing: center.delegate))")
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                NSLog("Notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                NSLog("User denied notification permissions")
            } else {
                NSLog("Notification permissions granted")
            }
            
            // Check current authorization status
            center.getNotificationSettings { settings in
                NSLog("Current notification authorization: \(settings.authorizationStatus.rawValue)")
                NSLog("Alert setting: \(settings.alertSetting.rawValue)")
                NSLog("Badge setting: \(settings.badgeSetting.rawValue)")
                
                if settings.authorizationStatus == .denied {
                    NSLog("⚠️ Notifications are DENIED - user needs to enable in System Preferences")
                }
            }
        }
    }

    private func loadConfiguration() {
        configuration = Configuration.load()
        if configuration == nil {
            requestConfigurationFromUser()
        } else {
            appLogic = AppLogic(apiKey: configuration.apiKey, timetaggerUrl: configuration.timetaggerUrl, configuration: configuration)
            appLogic.delegate = self
        }
    }

    // MARK: - Status Bar Setup
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        configureStatusBarButton()
        createStatusBarMenu()
    }
    
    private func createHashtagIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // Set up drawing context
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        
        // Use system color for menu bar icons
        NSColor.controlAccentColor.setStroke()
        NSColor.controlAccentColor.setFill()
        
        let lineWidth: CGFloat = 2.0
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        
        // Draw hashtag symbol
        let inset: CGFloat = 3.0
        let verticalSpacing: CGFloat = 4.0
        let horizontalSpacing: CGFloat = 4.0
        
        // Vertical lines
        let leftVerticalX = inset + horizontalSpacing
        let rightVerticalX = size.width - inset - horizontalSpacing
        
        context.move(to: CGPoint(x: leftVerticalX, y: inset))
        context.addLine(to: CGPoint(x: leftVerticalX, y: size.height - inset))
        context.strokePath()
        
        context.move(to: CGPoint(x: rightVerticalX, y: inset))
        context.addLine(to: CGPoint(x: rightVerticalX, y: size.height - inset))
        context.strokePath()
        
        // Horizontal lines
        let topHorizontalY = size.height - inset - verticalSpacing
        let bottomHorizontalY = inset + verticalSpacing
        
        context.move(to: CGPoint(x: inset, y: topHorizontalY))
        context.addLine(to: CGPoint(x: size.width - inset, y: topHorizontalY))
        context.strokePath()
        
        context.move(to: CGPoint(x: inset, y: bottomHorizontalY))
        context.addLine(to: CGPoint(x: size.width - inset, y: bottomHorizontalY))
        context.strokePath()
        
        image.unlockFocus()
        
        // Make it template image so it adapts to system appearance
        image.isTemplate = true
        
        return image
    }
    
    
    private func configureStatusBarButton() {
        guard let button = statusItem.button else { return }
        
        button.image = createHashtagIcon()
        button.title = ""
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
        
        let findTimeCubeMenuItem = NSMenuItem(title: "Find TimeCube", action: #selector(findTimeCube), keyEquivalent: "F")
        findTimeCubeMenuItem.isEnabled = true  // Start with Find enabled (no device connected)
        menu.addItem(findTimeCubeMenuItem)
        
        let forgetTimeCubeMenuItem = NSMenuItem(title: "Forget TimeCube", action: #selector(forgetTimeCube), keyEquivalent: "")
        forgetTimeCubeMenuItem.isEnabled = false  // Start with Forget disabled (no device connected)
        menu.addItem(forgetTimeCubeMenuItem)
        
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
        
        // Update menu title with current activity
        if isTracking && !currentActivity.isEmpty {
            menuItem.title = "Stop Tracking \(currentActivity)"
        } else {
            menuItem.title = "Stop Tracking"
        }
    }
    
    private func updateDeviceMenuState() {
        guard let menu = statusItem.menu else { return }
        
        // Find TimeCube menu item
        guard let findMenuItem = menu.item(at: MenuIndices.findTimeCube) else {
            NSLog("Error: Cannot find Find TimeCube menu item")
            return
        }
        
        // Forget TimeCube menu item  
        guard let forgetMenuItem = menu.item(at: MenuIndices.forgetTimeCube) else {
            NSLog("Error: Cannot find Forget TimeCube menu item")
            return
        }
        
        // Update based on connection state
        if isDeviceConnected {
            findMenuItem.isEnabled = false
            findMenuItem.action = nil
            forgetMenuItem.isEnabled = true
            forgetMenuItem.action = #selector(forgetTimeCube)
            NSLog("Menu updated: Device connected - Find disabled, Forget enabled")
        } else {
            findMenuItem.isEnabled = true
            findMenuItem.action = #selector(findTimeCube)
            forgetMenuItem.isEnabled = false
            forgetMenuItem.action = nil
            NSLog("Menu updated: Device disconnected - Find enabled, Forget disabled")
        }
    }

    @objc private func openTimetagger() {
        let timetaggerWebUrl = "\(configuration.timetaggerUrl)/timetagger/app/"
        if let url = URL(string: timetaggerWebUrl) {
            NSWorkspace.shared.open(url)
            NSLog("Opening Timetagger at: \(timetaggerWebUrl)")
        } else {
            NSLog("Invalid Timetagger URL: \(timetaggerWebUrl)")
        }
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

    @objc private func findTimeCube() {
        NSLog("Starting TimeCube discovery...")
        discoveredDevices.removeAll()
        bluetoothManager.startDiscoveryMode()
        
        // Send system notification that stays for 10 seconds
        let content = UNMutableNotificationContent()
        content.title = "TimeCube Discovery"
        content.body = "Searching for TimeCubes... (10 seconds)"
        content.sound = nil
        
        
        // Make notification persistent and visible
        content.categoryIdentifier = "DISCOVERY_SCANNING"
        content.threadIdentifier = "discovery"
        
        let request = UNNotificationRequest(identifier: "discovery-scanning", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Error sending discovery notification: \(error.localizedDescription)")
            }
        }
        
        // Remove the scanning notification after exactly 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["discovery-scanning"])
            
            // Send completion notification
            let completedContent = UNMutableNotificationContent()
            completedContent.title = "TimeCube Discovery Complete"
            completedContent.body = "Scan finished - showing results..."
            completedContent.sound = nil
            
            
            let completedRequest = UNNotificationRequest(identifier: "discovery-complete", content: completedContent, trigger: nil)
            UNUserNotificationCenter.current().add(completedRequest) { _ in }
        }
        
        // After 10 seconds, show results directly
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            NSLog("Main: 10 seconds elapsed, showing scan results...")
            self.showScanResultsDialog()
        }
    }
    
    private func showScanResultsDialog() {
        NSLog("Main: showScanResultsDialog called. Found \(discoveredDevices.count) devices.")
        
        if discoveredDevices.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Scan Complete"
            alert.informativeText = "No TimeCube devices were found during the 10-second scan. Make sure your TimeCube is turned on and in pairing mode."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Try again
                findTimeCube()
            }
            return
        }
        
        // Show found devices with summary
        let deviceList = discoveredDevices.map { device in
            let name = device.name ?? "Unknown TimeCube"
            let id = device.identifier.uuidString.prefix(8)
            return "• \(name) (\(id))"
        }.joined(separator: "\n")
        
        let alert = NSAlert()
        alert.messageText = "Found \(discoveredDevices.count) TimeCube(s)"
        alert.informativeText = "Devices found:\n\n\(deviceList)\n\nSelect which one to connect to:"
        alert.alertStyle = .informational
        
        // Create dropdown with device list
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        for device in discoveredDevices {
            let deviceName = device.name ?? "Unknown TimeCube"
            let identifier = device.identifier.uuidString.prefix(8)
            popup.addItem(withTitle: "\(deviceName) (\(identifier))")
        }
        
        alert.accessoryView = popup
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let selectedIndex = popup.indexOfSelectedItem
            if selectedIndex >= 0 && selectedIndex < discoveredDevices.count {
                let selectedDevice = discoveredDevices[selectedIndex]
                NSLog("User selected device: \(selectedDevice.name ?? "Unknown")")
                
                // Connection state will be updated in didConnectToDevice callback
                bluetoothManager.connectToDevice(selectedDevice)
            }
        }
    }
    
    @objc private func forgetTimeCube() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Forget TimeCube?"
            alert.informativeText = "This will disconnect and forget the current TimeCube. You'll need to use 'Find TimeCube' to reconnect."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSLog("User chose to forget TimeCube")
                
                // Update connection state immediately
                self.isDeviceConnected = false
                self.updateDeviceMenuState()
                
                self.bluetoothManager.forgetDevice()
                
                // Show confirmation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let confirmAlert = NSAlert()
                    confirmAlert.messageText = "TimeCube Forgotten"
                    confirmAlert.informativeText = "The TimeCube has been disconnected and forgotten. Use 'Find TimeCube' to connect to a device."
                    confirmAlert.alertStyle = .informational
                    confirmAlert.addButton(withTitle: "OK")
                    confirmAlert.runModal()
                }
            }
        }
    }
    
    @objc private func quit() {
        cleanup()
        NSApplication.shared.terminate(self)
    }

    // MARK: - BluetoothDeviceManagerDelegate
    func didConnectToDevice(data: Data) {
        let pageValue = extractPageFromData(data: data)
        
        // Update connection state
        isDeviceConnected = true
        
        // Clear discovery state after successful connection
        discoveredDevices.removeAll()
        NSLog("Main: Device connected, cleared discovery state")
        
        // Update menu state
        DispatchQueue.main.async {
            self.updateDeviceMenuState()
        }
        
        // Only start tracking if device shows an active page with description
        if pageValue != 0 && !(configuration.pageDescriptions[pageValue]?.isEmpty ?? true) {
            appLogic.startTracking(data: data)
        }
        // UI will be updated through AppLogicDelegate
    }

    func didDisconnectFromDevice(data: Data) {
        // Update connection state
        isDeviceConnected = false
        
        // Don't automatically stop tracking on Bluetooth disconnect
        // Let timer continue running so user sees how long they've been tracking
        // Events will be buffered until connection is restored
        NSLog("Device disconnected but keeping timer running for user awareness")
        
        // Clear discovery state on disconnection
        discoveredDevices.removeAll()
        NSLog("Main: Device disconnected, cleared discovery state")
        
        // Update menu state
        DispatchQueue.main.async {
            self.updateDeviceMenuState()
        }
    }

    func didUpdatePageChange(data: Data) {
        // Let AppLogic handle everything through delegate callbacks
        appLogic.didUpdatePageChange(data: data)
    }
    
    func didDiscoverDevice(_ peripheral: CBPeripheral, rssi: NSNumber) {
        DispatchQueue.main.async {
            NSLog("Main: didDiscoverDevice called for: \(peripheral.name ?? "Unknown") (RSSI: \(rssi))")
            self.discoveredDevices.append(peripheral)
            NSLog("Main: Total devices in list now: \(self.discoveredDevices.count)")
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
            
            button.image = self.createHashtagIcon()
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
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
        
        // Check connection state after a short delay to allow Bluetooth manager to initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let connected = self.bluetoothManager.isDeviceConnected()
            NSLog("Checking initial device connection state: \(connected)")
            self.isDeviceConnected = connected
            self.updateDeviceMenuState()
        }
    }
    
    private func setTrackingState(_ tracking: Bool) {
        isTracking = tracking
        if !tracking {
            startDate = nil
            currentActivity = ""
        }
        
        DispatchQueue.main.async {
            self.updateStopTrackingMenuState()
        }
    }
    
    // MARK: - AppLogicDelegate
    func didStartTracking(activity: String) {
        currentActivity = activity
        stopTimer()
        startTimer()
        updateTimerUI()
        setTrackingState(true)
    }
    
    func didStopTracking() {
        currentActivity = ""
        stopTimer()
        resetStatusBarIcon()
        setTrackingState(false)
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

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        NSLog("🔔🔔🔔 WILL PRESENT NOTIFICATION - DELEGATE CALLED!")
        NSLog("   ID: \(notification.request.identifier)")
        NSLog("   Title: '\(notification.request.content.title)'")
        NSLog("   Body: '\(notification.request.content.body)'")
        NSLog("   Trigger: \(String(describing: notification.request.trigger))")
        
        // Show notification even when app is in foreground (no sound)
        if #available(macOS 11.0, *) {
            completionHandler([.list, .banner, .badge])
        } else {
            completionHandler([.alert, .badge])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        NSLog("Did receive notification response: \(response.notification.request.identifier)")
        completionHandler()
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
