import Foundation
import UserNotifications

// MARK: - Constants
private enum Constants {
    static let defaultAppKeyLength = 8
    static let minimumTrackingDuration: Int64 = 10
    static let dayInSeconds: Int64 = 86400
    static let modificationTimeThreshold: (min: Int64, max: Int64) = (20, 60)
}

// MARK: - AppLogic Delegate
protocol AppLogicDelegate: AnyObject {
    func didStartTracking(activity: String)
    func didStopTracking()
}

// MARK: - AppLogic
final class AppLogic {
    weak var delegate: AppLogicDelegate?
    private let apiKey: String
    private let timetaggerUrl: String
    private var appKey: String
    private var startTime: Int64
    private var timetagger: TimetaggerHandler
    private var configuration: Configuration
    private var lastEvent: Data
    private var bufferedEvents: [(appKey: String, t1: Int64, t2: Int64, label: String, mt: Int, hidden: Bool)] = []
    
    // MARK: - Properties
    private var notificationQueue: [UNNotificationRequest] = []
    private var isNotificationInProgress = false
    private var isProcessingPageChange = false
    private let serialQueue = DispatchQueue(label: "com.tcube.tracking", qos: .userInitiated)

    // MARK: - Lifecycle
    init(apiKey: String, timetaggerUrl: String, configuration: Configuration) {
        self.apiKey = apiKey
        self.timetaggerUrl = timetaggerUrl
        self.appKey = ""
        self.startTime = 0
        self.timetagger = TimetaggerHandler(apiKey: apiKey, timetaggerUrl: "\(timetaggerUrl)/timetagger/api/v2/records")
        self.configuration = configuration
        self.lastEvent = Data()
        
        setupNetworkNotifications()
    }
    
    deinit {
        // Cleanup is handled by TimetaggerHandler
    }

    // MARK: - Private Methods
    private func setupNetworkNotifications() {
        // Network monitoring is now handled by TimetaggerHandler
        // We'll listen for its connection changes to send buffered events
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            if self?.timetagger.isConnected == true {
                self?.sendBufferedEvents()
            }
        }
    }
    
    private func generateRandomAppKey(length: Int = Constants.defaultAppKeyLength) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    // MARK: - Public Interface
    func startTracking(data: Data) {
        let page = extractPageFromData(data: data)
        guard let description = configuration.pageDescriptions[page], !description.isEmpty else {
            NSLog("Page \(page) is not defined or description is empty")
            return
        }
        
        NSLog("Started tracking for: \(description)")
        startTime = Int64(Date().timeIntervalSince1970)
        appKey = generateRandomAppKey()
        
        // Notify delegate immediately
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didStartTracking(activity: description)
        }
        
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: startTime, label: description) { [weak self] response in
            guard let self = self else { return }
            
            if let response = response {
                self.handleEventResponse(response: response, description: description)
            } else {
                NSLog("Error sending start tracking event - will buffer")
                self.showNotification(title: "Event Buffered", body: "Event: \(description) has been buffered.", type: "buffer")
                self.bufferEvent(appKey: self.appKey, t1: self.startTime, t2: self.startTime, label: description, hidden: false)
                
                // Notify delegate about potential connection issues but keep tracking
                // Timer will continue running until explicitly stopped
            }
        }
        
        lastEvent = data
    }

    func stopTracking(completion: (() -> Void)? = nil) {
        let lastPage = extractPageFromData(data: lastEvent)
        guard let lastDescription = configuration.pageDescriptions[lastPage] else {
            NSLog("Page \(lastPage) is not defined or description is empty")
            completion?()
            return
        }
        
        NSLog("Stopped tracking for: \(lastDescription)")
        let endTime = Int64(Date().timeIntervalSince1970)
        let duration = endTime - startTime
        
        // Check if tracking duration is too short
        if duration < Constants.minimumTrackingDuration {
            handleShortDurationTracking(endTime: endTime, description: lastDescription, completion: completion)
            return
        }
        
        // Get existing event and process accordingly
        processStopTracking(endTime: endTime, description: lastDescription, completion: completion)
    }

    func didUpdatePageChange(data: Data) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Prevent overlapping page change operations
            guard !self.isProcessingPageChange else {
                NSLog("Page change already in progress, ignoring")
                return
            }
            
            self.isProcessingPageChange = true
            defer { self.isProcessingPageChange = false }
            
            let lastPage = self.extractPageFromData(data: self.lastEvent)
            let currentPage = self.extractPageFromData(data: data)
            
            // Stop current tracking if there was an active page
            if lastPage != 0 {
                self.stopTracking { [weak self] in
                    guard let self = self else { return }
                    
                    // Start new tracking only after stop is complete
                    if let description = self.configuration.pageDescriptions[currentPage], !description.isEmpty {
                        NSLog("Changed page to: \(description)")
                        self.startTracking(data: data)
                    } else {
                        // Update last event for page 0 or undefined pages
                        self.lastEvent = data
                        if currentPage != 0 {
                            NSLog("Page \(currentPage) is not defined or description is empty")
                        }
                        
                        // Notify delegate about stopping
                        DispatchQueue.main.async { [weak self] in
                            self?.delegate?.didStopTracking()
                        }
                    }
                }
            } else {
                // No active tracking, just start new one if needed
                if let description = self.configuration.pageDescriptions[currentPage], !description.isEmpty {
                    NSLog("Changed page to: \(description)")
                    self.startTracking(data: data)
                } else {
                    // Update last event for page 0 or undefined pages
                    self.lastEvent = data
                    if currentPage != 0 {
                        NSLog("Page \(currentPage) is not defined or description is empty")
                    }
                }
            }
        }
    }

    private func extractPageFromData(data: Data) -> Int {
        return Int(data.first ?? 0)
    }
    
    private func handleShortDurationTracking(endTime: Int64, description: String, completion: (() -> Void)? = nil) {
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: endTime, label: description, hidden: true) { [weak self] response in
            if response != nil {
                self?.showNotification(title: "Event Cancelled", body: "Duration was less than 10 seconds", type: "cancel")
            } else {
                self?.bufferEvent(appKey: self?.appKey ?? "", t1: self?.startTime ?? 0, t2: endTime, label: description, hidden: true)
            }
            completion?()
        }
    }
    
    private func processStopTracking(endTime: Int64, description: String, completion: (() -> Void)? = nil) {
        timetagger.getExistingEvent(appKey: appKey, t1: startTime - Constants.dayInSeconds, t2: endTime) { [weak self] event in
            guard let self = self else { 
                completion?()
                return 
            }
            
            // Check if event is hidden
            if let event = event, let ds = event["ds"] as? String, ds.contains("HIDDEN") {
                NSLog("Event is hidden, skipping update")
                completion?()
                return
            }
            
            self.handleExistingEvent(event: event, endTime: endTime, description: description, completion: completion)
        }
    }
    
    private func handleExistingEvent(event: [String: Any]?, endTime: Int64, description: String, completion: (() -> Void)? = nil) {
        guard let event = event,
              let eventStartTime = event["t1"] as? Int64,
              let eventEndTime = event["t2"] as? Int64 else {
            // No existing event, send new one
            sendFinalEvent(startTime: startTime, endTime: endTime, description: description, completion: completion)
            return
        }
        
        let timeDifference = endTime - eventEndTime
        let shouldModifyEvent = eventStartTime != startTime || 
                               (timeDifference < Constants.modificationTimeThreshold.min || 
                                timeDifference > Constants.modificationTimeThreshold.max)
        
        if shouldModifyEvent {
            let finalEndTime = eventEndTime != eventStartTime ? eventEndTime : endTime
            sendFinalEvent(startTime: eventStartTime, endTime: finalEndTime, description: description, completion: completion)
        } else {
            sendFinalEvent(startTime: startTime, endTime: endTime, description: description, completion: completion)
        }
    }
    
    private func sendFinalEvent(startTime: Int64, endTime: Int64, description: String, completion: (() -> Void)? = nil) {
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: endTime, label: description) { [weak self] response in
            guard let self = self else { 
                completion?()
                return 
            }
            
            if let response = response {
                let duration = endTime - startTime
                self.handleEventResponse(response: response, description: description, duration: duration)
            } else {
                self.showNotification(title: "Event Buffered", body: "Event: \(description) has been buffered.", type: "buffer")
                self.bufferEvent(appKey: self.appKey, t1: startTime, t2: endTime, label: description, hidden: false)
            }
            completion?()
        }
    }
    
    private func bufferEvent(appKey: String, t1: Int64, t2: Int64, label: String, hidden: Bool) {
        let bufferedEvent = (appKey: appKey, t1: t1, t2: t2, label: label, mt: Int(Date().timeIntervalSince1970), hidden: hidden)
        bufferedEvents.append(bufferedEvent)
    }

    // MARK: - Notification Management
    private func showNotification(title: String, body: String, type: String = "general") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.threadIdentifier = "tracking-\(type)"
        
        // Use timestamp to ensure unique IDs but allow identification by type
        let identifier = "\(type)-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        NSLog("Queueing notification: \(title) - \(body)")
        notificationQueue.append(request)
        processNextNotification()
    }
    
    private func processNextNotification() {
        guard !notificationQueue.isEmpty, !isNotificationInProgress else {
            return
        }

        let nextNotification = notificationQueue.removeFirst()
        isNotificationInProgress = true

        NSLog("Processing notification: \(nextNotification.identifier) - \(nextNotification.content.title)")
        
        // Check notification settings before adding
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            NSLog("Notification settings - Auth: \(settings.authorizationStatus.rawValue), Alert: \(settings.alertSetting.rawValue)")
            
            UNUserNotificationCenter.current().add(nextNotification) { [weak self] error in
                if let error = error {
                    NSLog("Error adding notification: \(error.localizedDescription)")
                } else {
                    NSLog("Successfully added notification: \(nextNotification.identifier)")
                    
                    // Check pending notifications
                    UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                        NSLog("Pending notifications count: \(requests.count)")
                        for request in requests {
                            NSLog("Pending: \(request.identifier) - \(request.content.title)")
                        }
                    }
                }
                
                // Add longer delay between notifications so user can read them
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self?.isNotificationInProgress = false
                    self?.processNextNotification()
                }
            }
        }
    }

    private func handleEventResponse(response: [String: Any], description: String, duration: Int64? = nil) {
        guard let accepted = response["accepted"] as? [String], !accepted.isEmpty else {
            NSLog("Event rejected for: \(description)")
            return
        }
        
        let message: String
        if let duration = duration {
            let minutes = duration / 60
            let seconds = duration % 60
            message = "Finished tracking: \(description) (\(minutes)m \(seconds)s)"
            showNotification(title: "Event Accepted", body: message, type: "finish")
        } else {
            message = "Started tracking: \(description)"
            showNotification(title: "Event Accepted", body: message, type: "start")
        }
    }

    // MARK: - Buffered Events
    private func sendBufferedEvents() {
        guard !bufferedEvents.isEmpty else { return }
        
        let eventsToSend = bufferedEvents
        bufferedEvents.removeAll()
        
        for event in eventsToSend {
            timetagger.sendEvent(appKey: event.appKey, t1: event.t1, t2: event.t2, label: event.label, hidden: event.hidden) { response in
                if response != nil {
                    NSLog("Sent buffered event: \(event.label)")
                } else {
                    NSLog("Failed to send buffered event: \(event.label)")
                    // Re-add failed event to buffer
                    DispatchQueue.main.async {
                        self.bufferedEvents.append(event)
                    }
                }
            }
        }
    }
}
