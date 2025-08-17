import Foundation
import UserNotifications
import Network

// MARK: - Constants
private enum Constants {
    static let defaultAppKeyLength = 8
    static let minimumTrackingDuration: Int64 = 10
    static let dayInSeconds: Int64 = 86400
    static let modificationTimeThreshold: (min: Int64, max: Int64) = (20, 60)
}

// MARK: - AppLogic
final class AppLogic {
    private let apiKey: String
    private let timetaggerUrl: String
    private var appKey: String
    private var startTime: Int64
    private var timetagger: TimetaggerHandler
    private var configuration: Configuration
    private var lastEvent: Data
    private var monitor: NWPathMonitor
    private var bufferedEvents: [(appKey: String, t1: Int64, t2: Int64, label: String, mt: Int, hidden: Bool)] = []
    
    // MARK: - Properties
    private var notificationQueue: [UNNotificationRequest] = []
    private var isNotificationInProgress = false

    // MARK: - Lifecycle
    init(apiKey: String, timetaggerUrl: String, configuration: Configuration) {
        self.apiKey = apiKey
        self.timetaggerUrl = timetaggerUrl
        self.appKey = ""
        self.startTime = 0
        self.timetagger = TimetaggerHandler(apiKey: apiKey, timetaggerUrl: "\(timetaggerUrl)/timetagger/api/v2/records")
        self.configuration = configuration
        self.lastEvent = Data()
        
        self.monitor = NWPathMonitor()
        setupNetworkMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }

    // MARK: - Private Methods
    private func setupNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                NSLog("Internet connection restored")
                self?.sendBufferedEvents()
            } else {
                NSLog("No internet connection")
            }
        }
        
        let queue = DispatchQueue.global(qos: .background)
        monitor.start(queue: queue)
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
        
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: startTime, label: description) { [weak self] response in
            guard let self = self else { return }
            
            if let response = response {
                self.handleEventResponse(response: response, description: description)
            } else {
                NSLog("Error sending start tracking event")
                self.showNotification(title: "Event Buffered", body: "Event: \(description) has been buffered.")
                self.bufferEvent(appKey: self.appKey, t1: self.startTime, t2: self.startTime, label: description, hidden: false)
            }
        }
        
        lastEvent = data
    }

    func stopTracking() {
        let lastPage = extractPageFromData(data: lastEvent)
        guard let lastDescription = configuration.pageDescriptions[lastPage] else {
            NSLog("Page \(lastPage) is not defined or description is empty")
            return
        }
        
        NSLog("Stopped tracking for: \(lastDescription)")
        let endTime = Int64(Date().timeIntervalSince1970)
        let duration = endTime - startTime
        
        // Check if tracking duration is too short
        if duration < Constants.minimumTrackingDuration {
            handleShortDurationTracking(endTime: endTime, description: lastDescription)
            return
        }
        
        // Get existing event and process accordingly
        processStopTracking(endTime: endTime, description: lastDescription)
    }

    func didUpdatePageChange(data: Data) {
        let lastPage = extractPageFromData(data: lastEvent)
        let currentPage = extractPageFromData(data: data)
        
        // Stop current tracking if there was an active page
        if lastPage != 0 {
            stopTracking()
        }
        
        // Start new tracking if new page has description
        if let description = configuration.pageDescriptions[currentPage], !description.isEmpty {
            NSLog("Changed page to: \(description)")
            startTracking(data: data)
        } else {
            // Update last event for page 0 or undefined pages
            lastEvent = data
            if currentPage != 0 {
                NSLog("Page \(currentPage) is not defined or description is empty")
            }
        }
    }

    private func extractPageFromData(data: Data) -> Int {
        return Int(data.first ?? 0)
    }
    
    private func handleShortDurationTracking(endTime: Int64, description: String) {
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: endTime, label: description, hidden: true) { [weak self] response in
            if response != nil {
                self?.showNotification(title: "Event Cancelled", body: "Duration was less than 10 seconds")
            } else {
                self?.bufferEvent(appKey: self?.appKey ?? "", t1: self?.startTime ?? 0, t2: endTime, label: description, hidden: true)
            }
        }
    }
    
    private func processStopTracking(endTime: Int64, description: String) {
        timetagger.getExistingEvent(appKey: appKey, t1: startTime - Constants.dayInSeconds, t2: endTime) { [weak self] event in
            guard let self = self else { return }
            
            // Check if event is hidden
            if let event = event, let ds = event["ds"] as? String, ds.contains("HIDDEN") {
                NSLog("Event is hidden, skipping update")
                return
            }
            
            self.handleExistingEvent(event: event, endTime: endTime, description: description)
        }
    }
    
    private func handleExistingEvent(event: [String: Any]?, endTime: Int64, description: String) {
        guard let event = event,
              let eventStartTime = event["t1"] as? Int64,
              let eventEndTime = event["t2"] as? Int64 else {
            // No existing event, send new one
            sendFinalEvent(startTime: startTime, endTime: endTime, description: description)
            return
        }
        
        let timeDifference = endTime - eventEndTime
        let shouldModifyEvent = eventStartTime != startTime || 
                               (timeDifference < Constants.modificationTimeThreshold.min || 
                                timeDifference > Constants.modificationTimeThreshold.max)
        
        if shouldModifyEvent {
            let finalEndTime = eventEndTime != eventStartTime ? eventEndTime : endTime
            sendFinalEvent(startTime: eventStartTime, endTime: finalEndTime, description: description)
        } else {
            sendFinalEvent(startTime: startTime, endTime: endTime, description: description)
        }
    }
    
    private func sendFinalEvent(startTime: Int64, endTime: Int64, description: String) {
        timetagger.sendEvent(appKey: appKey, t1: startTime, t2: endTime, label: description) { [weak self] response in
            guard let self = self else { return }
            
            if let response = response {
                // Duration should be calculated from current session start time, not the event startTime
                let duration = endTime - self.startTime
                self.handleEventResponse(response: response, description: description, duration: duration)
            } else {
                self.showNotification(title: "Event Buffered", body: "Event: \(description) has been buffered.")
                self.bufferEvent(appKey: self.appKey, t1: startTime, t2: endTime, label: description, hidden: false)
            }
        }
    }
    
    private func bufferEvent(appKey: String, t1: Int64, t2: Int64, label: String, hidden: Bool) {
        let bufferedEvent = (appKey: appKey, t1: t1, t2: t2, label: label, mt: Int(Date().timeIntervalSince1970), hidden: hidden)
        bufferedEvents.append(bufferedEvent)
    }

    // MARK: - Notification Management
    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationQueue.append(request)
        processNextNotification()
    }
    
    private func processNextNotification() {
        guard !notificationQueue.isEmpty, !isNotificationInProgress else {
            return
        }

        let nextNotification = notificationQueue.removeFirst()
        isNotificationInProgress = true

        UNUserNotificationCenter.current().add(nextNotification) { [weak self] error in
            if let error = error {
                NSLog("Error adding notification: \(error.localizedDescription)")
            }
            self?.isNotificationInProgress = false
            self?.processNextNotification()
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
        } else {
            message = "Started tracking: \(description)"
        }
        showNotification(title: "Event Accepted", body: message)
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
