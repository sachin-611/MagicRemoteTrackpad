import Foundation
import Network
import CoreGraphics

// The port matching your Android app's configuration
let PORT: UInt16 = 12345

class MacRemoteServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.remote.server.queue")
    private let gestureQueue = DispatchQueue(label: "com.remote.server.gestureQueue")
    private var isLeftDown = false

    init() {
        setupListener()
    }

    func start() {
        print("🚀 Server starting...")
        listener?.start(queue: queue)
        print("✅ Server is running. Listening on UDP port \(PORT)")
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

            self.listener?.stateUpdateHandler = { state in
                switch state {
                case .failed(_):
                    exit(1)
                default:
                    break
                }
            }

            self.listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

        } catch {
            exit(1)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }

            if let error = error {
                print("📩 Receive error: \(error)")
                // Check if the connection is still viable
                if case .posix(let code) = error, code == .ECANCELED {
                    return
                }
            } else if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8) {
                    self.processMessage(message, from: connection)
                }
            }

            // Always re-register the receive handler loop unless the connection is cancelled/failed
            if connection.state == .ready || connection.state == .preparing || connection.state == .setup {
                self.receiveData(on: connection)
            }
        }
    }

    private func processMessage(_ message: String, from connection: NWConnection) {
        let cleanedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = cleanedMessage.components(separatedBy: ",")
        guard !components.isEmpty else {
            return
        }

        let command = components[0]

        switch command {
        case "MOVE":
            if components.count == 3, let dx = Double(components[1]), let dy = Double(components[2]) {
                moveMouse(dx: dx, dy: dy)
            }
        case "GESTURE":
            if components.count >= 2 {
                let gestureType = components[1]
                let modifier = components.count >= 3 ? components[2] : "control"
                executeGesture(type: gestureType, modifier: modifier)
            }
        case "SCROLL":
            if components.count == 3, let dx = Int(components[1]), let dy = Int(components[2]) {
                scrollMouse(dx: dx, dy: dy)
            }
        case "CLICK":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            leftClick(clickCount: clickCount)
        case "PING":
            sendPong(to: connection)
        case "LEFT_DOWN":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            isLeftDown = true
            postClickEvent(type: .leftMouseDown, button: .left, clickCount: clickCount)
        case "LEFT_UP":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            isLeftDown = false
            postClickEvent(type: .leftMouseUp, button: .left, clickCount: clickCount)
        case "RIGHT_CLICK":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            rightClick(clickCount: clickCount)
        default:
            break
        }
    }

    private func postClickEvent(type: CGEventType, button: CGMouseButton, clickCount: Int64 = 1) {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentLoc, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }

    private func scrollMouse(dx: Int, dy: Int) {
        // CGEvent(scrollWheelEvent2Source:...) is used for scrolling
        // wheel1 is vertical, wheel2 is horizontal
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            return
        }
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func leftClick(clickCount: Int64) {
        postClickEvent(type: .leftMouseDown, button: .left, clickCount: clickCount)
        postClickEvent(type: .leftMouseUp, button: .left, clickCount: clickCount)
    }

    private func rightClick(clickCount: Int64) {
        postClickEvent(type: .rightMouseDown, button: .right, clickCount: clickCount)
        postClickEvent(type: .rightMouseUp, button: .right, clickCount: clickCount)
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
    }

    private func executeGesture(type: String, modifier: String) {
        switch type {
        case "swipe_up":
            // Keycode 126 is Up Arrow
            triggerSystemEvent(keyCode: 126, modifier: modifier)
        case "swipe_down":
            // Keycode 125 is Down Arrow
            triggerSystemEvent(keyCode: 125, modifier: modifier)
        case "swipe_left":
            // Keycode 123 is Left Arrow
            triggerSystemEvent(keyCode: 123, modifier: modifier)
        case "swipe_right":
            // Keycode 124 is Right Arrow
            triggerSystemEvent(keyCode: 124, modifier: modifier)
//         case "page_back":
//             // Keycode 33 is '['
//             triggerSystemEvent(keyCode: 33, modifier: "command")
//         case "page_forward":
//             // Keycode 30 is ']'
//             triggerSystemEvent(keyCode: 30, modifier: "command")
        default:
            break
        }
    }

    private func triggerSystemEvent(keyCode: Int, modifier: String) {
        // Run AppleScript on a separate serial queue to prevent blocking the network queue
        // and to ensure gestures are executed in the order they are received.
        gestureQueue.async {
            let scriptSource = "tell application \"System Events\" to key code \(keyCode) using \(modifier) down"
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&error)
                if let err = error {
                    print("🍎 AppleScript Error: \(err)")
                }
            }
        }
    }

    private func sendPong(to connection: NWConnection) {
        let computerName = Host.current().localizedName ?? "Mac"
        let pongData = "PONG,\(computerName)".data(using: .utf8)
        connection.send(content: pongData, completion: .contentProcessed({ _ in }))
    }
}

// Instantiate and launch the server
let server = MacRemoteServer()
server.start()
