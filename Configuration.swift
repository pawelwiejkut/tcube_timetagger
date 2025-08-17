import Foundation

// MARK: - Configuration
struct Configuration: Codable {
    let apiKey: String
    let timetaggerUrl: String
    let pageDescriptions: [Int: String]

    // MARK: - Constants
    private enum ConfigurationConstants {
        static let configDirectoryName = ".tcube-timetagger"
        static let configFileName = "config.json"
    }
    
    // MARK: - Private Methods
    private static func configDirectory() -> URL? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        
        let configDir = homeDirectory.appendingPathComponent(ConfigurationConstants.configDirectoryName)
        
        if !fileManager.fileExists(atPath: configDir.path) {
            do {
                try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                NSLog("Error creating configuration directory: \(error.localizedDescription)")
                return nil
            }
        }
        
        return configDir.appendingPathComponent(ConfigurationConstants.configFileName)
    }

    // MARK: - Public Interface
    static func load() -> Configuration? {
        guard let url = configDirectory() else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(Configuration.self, from: data)
        } catch {
            NSLog("Error loading configuration: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ configuration: Configuration) -> Bool {
        guard let url = configDirectory() else {
            return false
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(configuration)
            try data.write(to: url)
            return true
        } catch {
            NSLog("Error saving configuration: \(error.localizedDescription)")
            return false
        }
    }
}
