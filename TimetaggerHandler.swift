import Foundation
import Network

// MARK: - Constants
private enum NetworkConstants {
    static let httpStatusOK = 200
    static let defaultTimeout: TimeInterval = 30.0
}

// MARK: - TimetaggerHandler
final class TimetaggerHandler {
    // MARK: - Properties
    private let apiKey: String
    private let timetaggerUrl: String
    private let connectionMonitor: NWPathMonitor
    private(set) var isConnected: Bool = false

    // MARK: - Lifecycle
    init(apiKey: String, timetaggerUrl: String) {
        self.apiKey = apiKey
        self.timetaggerUrl = timetaggerUrl
        self.connectionMonitor = NWPathMonitor()
        
        setupNetworkMonitoring()
    }
    
    deinit {
        connectionMonitor.cancel()
    }
    
    // MARK: - Private Methods
    private func setupNetworkMonitoring() {
        connectionMonitor.pathUpdateHandler = { [weak self] path in
            let wasConnected = self?.isConnected ?? false
            self?.isConnected = path.status == .satisfied
            
            if !wasConnected && path.status == .satisfied {
                NSLog("Internet connection restored")
            } else if wasConnected && path.status != .satisfied {
                NSLog("Internet connection lost")
            }
        }
        
        let queue = DispatchQueue.global(qos: .utility)
        connectionMonitor.start(queue: queue)
    }

    // MARK: - Public Interface
    func sendEvent(appKey: String, t1: Int64, t2: Int64, label: String, hidden: Bool = false, completion: @escaping ([String: Any]?) -> Void) {
        
        let ds = hidden ? "HIDDEN \(label)" : label
        let event: [[String: Any]] = [[
            "key": appKey,
            "mt": Int(Date().timeIntervalSince1970),
            "t1": t1,
            "t2": t2,
            "ds": ds,
            "st": 0.0
        ]]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event) else {
            NSLog("Error serializing JSON")
            completion(nil)
            return
        }
        
        guard let url = URL(string: timetaggerUrl) else {
            NSLog("Invalid timetagger URL")
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "authtoken")
        request.timeoutInterval = NetworkConstants.defaultTimeout
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            self.handleEventResponse(data: data, response: response, error: error, completion: completion)
        }.resume()
    }

    func getExistingEvent(appKey: String, t1: Int64, t2: Int64, completion: @escaping ([String: Any]?) -> Void) {
        let urlStr = "\(timetaggerUrl)?timerange=\(t1)-\(t2)"
        
        guard let url = URL(string: urlStr) else {
            NSLog("Invalid URL: \(urlStr)")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "authtoken")
        request.timeoutInterval = NetworkConstants.defaultTimeout

        URLSession.shared.dataTask(with: request) { data, response, error in
            self.handleGetEventResponse(appKey: appKey, data: data, response: response, error: error, completion: completion)
        }.resume()
    }
    
    // MARK: - Response Handlers
    private func handleEventResponse(data: Data?, response: URLResponse?, error: Error?, completion: @escaping ([String: Any]?) -> Void) {
        if let error = error {
            NSLog("Error sending event: \(error.localizedDescription)")
            completion(nil)
            return
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            NSLog("Invalid response type")
            completion(nil)
            return
        }
        
        guard httpResponse.statusCode == NetworkConstants.httpStatusOK else {
            NSLog("API error with status code: \(httpResponse.statusCode)")
            completion(nil)
            return
        }
        
        guard let data = data else {
            NSLog("No data in response")
            completion(nil)
            return
        }
        
        do {
            if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                completion(jsonResponse)
            } else {
                NSLog("Invalid response format")
                completion(nil)
            }
        } catch {
            NSLog("Error parsing JSON response: \(error.localizedDescription)")
            completion(nil)
        }
    }
    
    private func handleGetEventResponse(appKey: String, data: Data?, response: URLResponse?, error: Error?, completion: @escaping ([String: Any]?) -> Void) {
        if let error = error {
            NSLog("Error getting existing event: \(error.localizedDescription)")
            completion(nil)
            return
        }
        
        guard let data = data else {
            NSLog("No data in response")
            completion(nil)
            return
        }
        
        do {
            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let records = jsonResponse["records"] as? [[String: Any]] else {
                NSLog("Invalid JSON format or missing 'records' key")
                completion(nil)
                return
            }
            
            // Find matching record by appKey
            for record in records {
                if let key = record["key"] as? String, key == appKey {
                    completion(record)
                    return
                }
            }
            
            // No matching record found
            completion(nil)
        } catch {
            NSLog("Error parsing JSON: \(error.localizedDescription)")
            completion(nil)
        }
    }
}
