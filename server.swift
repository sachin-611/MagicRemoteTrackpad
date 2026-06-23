import Foundation
import Network
import CoreGraphics
import os

// The port matching your Android app's configuration
let PORT: UInt16 = 12345

class MacRemoteServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.remote.server.queue")
    private var isLeftDown = false

    // Initialize the native macOS logger
    private let logger = Logger(subsystem: "com.remote.trackpad", category: "Server")
    
    init() {
        setupListener()
    }
    
    func start() {
        logger.info("🚀 Initializing Trackpad Server subsystem...")
        listener?.start(queue: queue)
        dispatchMain() // Keeps the command-line execution alive
    }
    
    private func setupListener() {
        do {
            // Configure UDP parameters and enable peer-to-peer sharing for discovery
            let params = NWParameters.udp
            params.includePeerToPeer = true
            
            self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PORT)!)
            
            // Broadcast the server across the local Wi-Fi network using Bonjour/mDNS
            self.listener?.service = NWListener.Service(name: "Mac Remote Trackpad", type: "_remotepad._udp")
            
            self.listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.logger.info("✅ Server is actively listening on port \(PORT) and broadcasting via Bonjour.")
                case .failed(let error):
                    self.logger.fault("❌ Server failed to bind to port \(PORT). Fatal error: \(error.localizedDescription, privacy: .public)")
                    exit(1)
                case .cancelled:
                    self.logger.warning("⚠️ Server listener was cancelled.")
                case .setup:
                    self.logger.debug("⚙️ Server is setting up network interfaces.")
                case .waiting(let error):
                    self.logger.warning("⏳ Server is waiting for a viable network interface: \(error.localizedDescription, privacy: .public)")
                @unknown default:
                    break
                }
            }
            
            self.listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
        } catch {
            logger.fault("❌ Failed to initialize network listener: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let remoteEndpoint = connection.endpoint
        logger.info("🔗 New inbound UDP data flow initiated from client: \(remoteEndpoint.debugDescription, privacy: .public)")
        
        connection.start(queue: queue)
        receiveData(on: connection)
    }
    
    private func receiveData(on connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("❌ Error receiving packet data: \(error.localizedDescription, privacy: .public)")
                return
            }
            
            if let data = data, !data.isEmpty {
                // Ensure byte count logs are also visible
                self.logger.debug("📥 Received packet payload: \(data.count, privacy: .public) bytes")
                
                if let message = String(data: data, encoding: .utf8) {
                    self.processMessage(message)
                } else {
                    self.logger.warning("⚠️ Received a packet that could not be decoded as valid UTF-8 string data.")
                }
            }
            
            // Re-register the receive handler loop for the next UDP packet
            self.receiveData(on: connection)
        }
    }
    
    private func processMessage(_ message: String) {
        let cleanedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = cleanedMessage.components(separatedBy: ",")
        guard !components.isEmpty else { 
            logger.warning("⚠️ Received an empty or malformed string payload.")
            return 
        }
        
        let command = components[0]
        
        switch command {
        case "MOVE":
            if components.count == 3, let dx = Double(components[1]), let dy = Double(components[2]) {
                logger.debug("📊 Parsed command: MOVE | dx: \(dx, privacy: .public) | dy: \(dy, privacy: .public)")
                moveMouse(dx: dx, dy: dy)
            } else {
                logger.warning("⚠️ Malformed MOVE command payload sequence received: '\(cleanedMessage, privacy: .public)'")
            }
        case "GESTURE":
            if components.count >= 2 {
                let gestureType = components[1]
                let modifier = components.count >= 3 ? components[2] : "control"
                logger.info("💥 Parsed command: GESTURE | Type: \(gestureType, privacy: .public) | Modifier: \(modifier, privacy: .public)")
                executeGesture(type: gestureType, modifier: modifier)
            } else {
                logger.warning("⚠️ Malformed GESTURE command payload sequence received: '\(cleanedMessage, privacy: .public)'")
            }
        case "SCROLL":
            if components.count == 3, let dx = Int(components[1]), let dy = Int(components[2]) {
                logger.debug("📜 Parsed command: SCROLL | dx: \(dx, privacy: .public) | dy: \(dy, privacy: .public)")
                scrollMouse(dx: dx, dy: dy)
            } else {
                logger.warning("⚠️ Malformed SCROLL command payload sequence received: '\(cleanedMessage, privacy: .public)'")
            }
        case "CLICK":
            logger.info("🖱️ Parsed command: LEFT CLICK")
            leftClick()
        case "LEFT_DOWN":
            logger.info("🖱️ Parsed command: LEFT BUTTON DOWN")
            isLeftDown = true
            postClickEvent(type: .leftMouseDown, button: .left)
        case "LEFT_UP":
            logger.info("🖱️ Parsed command: LEFT BUTTON UP")
            isLeftDown = false
            postClickEvent(type: .leftMouseUp, button: .left)
        case "RIGHT_CLICK":
            logger.info("🖱️ Parsed command: RIGHT CLICK")
            rightClick()
        default:
            logger.warning("❓ Unrecognized execution command identifier received: '\(command, privacy: .public)'")
            break
        }
    }

    private func postClickEvent(type: CGEventType, button: CGMouseButton) {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentLoc, mouseButton: button)
        event?.post(tap: .cghidEventTap)
    }

    private func scrollMouse(dx: Int, dy: Int) {
        // CGEvent(scrollWheelEvent2Source:...) is used for scrolling
        // wheel1 is vertical, wheel2 is horizontal
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            logger.error("❌ Failed to allocate CGEvent structure for scroll mapping.")
            return
        }
        scrollEvent.post(tap: .cghidEventTap)
        logger.debug("📜 Scroll event executed with dx: \(dx, privacy: .public), dy: \(dy, privacy: .public)")
    }

    private func leftClick() {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let leftDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentLoc, mouseButton: .left)
        let leftUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentLoc, mouseButton: .left)

        leftDown?.post(tap: .cghidEventTap)
        leftUp?.post(tap: .cghidEventTap)
        logger.debug("🖱️ Left click executed at current cursor position.")
    }

    private func rightClick() {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let rightDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: currentLoc, mouseButton: .right)
        let rightUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: currentLoc, mouseButton: .right)

        rightDown?.post(tap: .cghidEventTap)
        rightUp?.post(tap: .cghidEventTap)
        logger.debug("🖱️ Right click executed at current cursor position.")
    }
    
    private func moveMouse(dx: Double, dy: Double) {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let newX = currentLoc.x + CGFloat(dx)
        let newY = currentLoc.y + CGFloat(dy)
        let targetPoint = CGPoint(x: newX, y: newY)
        
        let eventType: CGEventType = isLeftDown ? .leftMouseDragged : .mouseMoved

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: targetPoint, mouseButton: .left) else {
            return
        }
        
        moveEvent.post(tap: .cghidEventTap)
        logger.debug("🖱️ Motion: \(eventType == .leftMouseDragged ? "DRAG" : "MOVE") to (\(Int(newX)), \(Int(newY)))")
    }
    
    private func executeGesture(type: String, modifier: String) {
        switch type {
        case "swipe_up":
            logger.info("🖥️ Executing AppleScript hook: Mission Control.")
            // Keycode 126 is Up Arrow
            triggerSystemEvent(keyCode: 126, modifier: modifier)
        case "swipe_down":
            logger.info("🔽 Executing AppleScript hook: App Exposé.")
            // Keycode 125 is Down Arrow
            triggerSystemEvent(keyCode: 125, modifier: modifier)
        case "swipe_left":
            logger.info("◀️ Executing AppleScript hook: Move Left One Space.")
            // Keycode 123 is Left Arrow
            triggerSystemEvent(keyCode: 123, modifier: modifier)
        case "swipe_right":
            logger.info("▶️ Executing AppleScript hook: Move Right One Space.")
            // Keycode 124 is Right Arrow
            triggerSystemEvent(keyCode: 124, modifier: modifier)
        default:
            logger.warning("⚠️ Attempted to execute an unmapped gesture action sequence: '\(type, privacy: .public)'")
            break
        }
    }
    
    private func triggerSystemEvent(keyCode: Int, modifier: String) {
        // This completely bypasses CGEvent and asks the OS directly to press the keys
        let scriptSource = "tell application \"System Events\" to key code \(keyCode) using \(modifier) down"
        
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            script.executeAndReturnError(&error)
            
            if error != nil {
                // If AppleScript fails, it's almost always a permissions issue.
                logger.error("❌ AppleScript execution failed. Check System Settings > Privacy & Security > Automation.")
            } else {
                logger.debug("⌨️ System Events successfully fired keycode \(keyCode, privacy: .public) with \(modifier, privacy: .public)")
            }
        }
    }
}

// Instantiate and launch the server
let server = MacRemoteServer()
server.start()
