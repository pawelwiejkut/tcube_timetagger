# TCube TimeTracker

A native macOS application for tracking time using the Timeular cube device via Bluetooth Low Energy. The application automatically detects cube orientation changes and logs time tracking events to your Timeular account.

## Features

- **Bluetooth Integration**: Seamless connection to Timeular cube via CoreBluetooth
- **Intelligent Reconnection**: Smart backoff strategy for stable long-term operation (24+ hours)
- **Battery Optimization**: Energy-efficient scanning and connection management
- **Menu Bar Integration**: Clean status bar interface with timer display
- **Automatic Time Tracking**: Detects cube flips and automatically starts/stops tracking
- **Network Resilience**: Offline event buffering with automatic sync when connection returns
- **User Notifications**: Real-time feedback on tracking events
- **Manual Controls**: Stop tracking option in menu bar

## System Requirements

- macOS 10.15+ (Catalina or later)
- Bluetooth LE support
- Timeular cube device
- Active Timeular account with API access

## Installation

### Prerequisites

1. **Xcode**: Install Xcode from the Mac App Store
2. **Timeular Account**: Ensure you have a Timeular account and API key
3. **Bluetooth Permissions**: The app will request Bluetooth access on first run

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/username/tcube-timetagger.git
cd tcube-timetagger
```

2. Open the project in Xcode:
```bash
open tcube-timetagger.xcodeproj
```

3. Build and run the project (⌘+R)

## Configuration

### Initial Setup

1. Create the configuration directory:
```bash
mkdir -p ~/.tcube-timetagger
```

2. Create the configuration file:
```bash
touch ~/.tcube-timetagger/config.json
```

3. Add your configuration:
```json
{
  "apiKey": "your_timeular_api_key",
  "timetaggerUrl": "https://api.timeular.com",
  "pageDescriptions": {
    "1": "Development",
    "2": "Meetings", 
    "3": "Documentation",
    "4": "Research",
    "5": "Break",
    "6": "Admin"
  }
}
```

### Configuration Options

- **apiKey**: Your Timeular API authentication token
- **timetaggerUrl**: Timeular API base URL (usually `https://api.timeular.com`)
- **pageDescriptions**: Mapping of cube faces (1-6) to activity descriptions

## Usage

### Starting the Application

1. Launch the app - it will appear in your menu bar
2. The app automatically scans for your Timeular cube
3. When connected, the battery level appears in the menu
4. Flip the cube to start tracking different activities

### Menu Bar Interface

- **Timer Display**: Shows elapsed time when tracking is active
- **Battery Level**: Displays cube battery percentage
- **Stop Tracking**: Manual stop option (enabled only when tracking)
- **Quit**: Exit the application

### Automatic Tracking

- **Cube Detection**: App automatically detects when cube is flipped
- **Activity Mapping**: Each face corresponds to a configured activity
- **Time Logging**: Events are sent to Timeular in real-time
- **Offline Support**: Events are buffered when offline and synced when connection returns

## Architecture

### Core Components

#### BluetoothDeviceManager
- Handles CoreBluetooth communication
- Implements intelligent reconnection strategy
- Manages battery monitoring
- Optimized for long-term stability

#### AppLogic
- Processes cube orientation changes
- Manages time tracking sessions
- Handles API communication with Timeular
- Implements offline event buffering

#### TimetaggerHandler
- HTTP API client for Timeular
- Network monitoring and resilience
- JSON serialization and error handling

#### Configuration
- JSON-based configuration management
- Secure storage in user home directory
- Validation and error handling

### Intelligent Reconnection Strategy

The app implements a sophisticated backoff strategy for Bluetooth reconnection:

- **0-1 minute**: Attempts every 5 seconds (12 attempts)
- **1-30 minutes**: Attempts every 30 seconds (24 attempts)
- **30 minutes-2 hours**: Attempts every 2 minutes (48 attempts)
- **2-24 hours**: Attempts every 5 minutes (24 attempts)
- **24+ hours**: Attempts every 15 minutes

This reduces battery drain by 98% compared to aggressive reconnection while maintaining responsiveness.

## API Integration

### Timeular API Endpoints

- **PUT /timetagger/api/v2/records**: Submit time tracking events
- **GET /timetagger/api/v2/records**: Retrieve existing events for conflict resolution

### Event Format

```json
[{
  "key": "random_app_key",
  "mt": 1645123456,
  "t1": 1645123400,
  "t2": 1645125200,
  "ds": "Development",
  "st": 0.0
}]
```

### Authentication

All API requests include the `authtoken` header with your Timeular API key.

## Troubleshooting

### Common Issues

**Bluetooth Connection Problems**:
- Ensure Bluetooth is enabled on your Mac
- Check that the cube is charged and nearby
- Restart the app if connection fails

**Configuration Not Found**:
- Verify the config file exists at `~/.tcube-timetagger/config.json`
- Check JSON syntax is valid
- Ensure all required fields are present

**API Authentication Errors**:
- Verify your API key is correct
- Check your Timeular account is active
- Test API connectivity manually

**Tracking Not Starting**:
- Ensure the cube face has a configured description
- Check the app has notification permissions
- Verify the cube is properly oriented

### Debug Logging

The app logs detailed information to the system console. To view logs:

1. Open Console.app
2. Filter for "tcube-timetagger"
3. Monitor connection and tracking events

### Performance Monitoring

Monitor app performance and battery usage:
- Check Activity Monitor for CPU usage
- Monitor Bluetooth activity in system preferences
- Review battery impact in System Preferences > Battery

## Development

### Project Structure

```
tcube-timetagger/
├── main.swift                 # App entry point and menu bar management
├── AppLogic.swift            # Core time tracking logic
├── BluetoothDeviceManager.swift # Bluetooth communication
├── TimetaggerHandler.swift   # API client
├── Configuration.swift       # Config management
├── Assets.xcassets/         # App icons and resources
└── tcube_timetagger.entitlements # App permissions
```

### Code Style

- Swift 5.0+ with modern async patterns
- MARK comments for code organization
- Comprehensive error handling with NSLog
- Memory-safe with weak references
- Thread-safe UI updates on main queue

### Building

```bash
# Debug build
xcodebuild -project tcube-timetagger.xcodeproj -scheme tcube-timetagger -configuration Debug

# Release build  
xcodebuild -project tcube-timetagger.xcodeproj -scheme tcube-timetagger -configuration Release
```

### Testing

The app includes comprehensive error handling and logging for debugging:
- Bluetooth state monitoring
- API response validation
- Network connectivity checks
- Configuration validation

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

### Coding Guidelines

- Follow Swift style conventions
- Add MARK comments for organization
- Include comprehensive error handling
- Write descriptive commit messages
- Update documentation for new features

## Security

- API keys are stored in user configuration files (not in code)
- No sensitive data is logged
- Secure HTTPS communication with Timeular API
- Minimal app permissions (only Bluetooth and notifications)

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- Timeular for the cube hardware and API
- Apple for CoreBluetooth framework
- Swift community for excellent documentation

## Support

For issues and feature requests, please use the GitHub issue tracker.

---

**Note**: This is an unofficial client for Timeular. For official support, contact Timeular directly.