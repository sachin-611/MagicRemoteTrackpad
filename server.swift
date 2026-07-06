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
    private var currentClickCount: Int64 = 1

    // Internal cursor tracking to prevent "stuttering" lag
    private var lastKnownMousePos: CGPoint?
    private var movePacketCount = 0

    private var isAtTopEdge = false
    private var isAtBottomEdge = false

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
            let params = NWParameters.udp
            params.includePeerToPeer = true

            self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PORT)!)
            self.listener?.service = NWListener.Service(name: "Mac Remote Trackpad", type: "_remotepad._udp")

            self.listener?.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    print("❌ Listener failed: \(error)")
                    exit(1)
                case .ready:
                    print("📡 Listener ready on port \(PORT)")
                default:
                    break
                }
            }

            self.listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

        } catch {
            print("❌ Setup error: \(error)")
            exit(1)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("⚠️ Connection error: \(error)")
            }
        }
        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.processData(data, from: connection)
            }

            if error == nil && (connection.state == .ready || connection.state == .preparing) {
                self.receiveData(on: connection)
            }
        }
    }

    private func processData(_ data: Data, from connection: NWConnection) {
        let firstByte = data[0]

        // Binary Protocol: Commands are 1-10
        // String Protocol: Commands start with letters (e.g., 'M', 'G', 'P')
        if firstByte > 0 && firstByte < 20 {
            processBinaryMessage(data, from: connection)
        } else if let message = String(data: data, encoding: .utf8) {
            processStringMessage(message, from: connection)
        }

        // Reset internal mouse pos on any non-move event to keep sync
        if firstByte != 1 {
            lastKnownMousePos = nil
        }
    }

    private func processBinaryMessage(_ data: Data, from connection: NWConnection) {
        let command = data[0]

        switch command {
        case 1: // MOVE (dx: Float32, dy: Float32)
            if data.count >= 9 {
                let dx = readFloat32(data: data, offset: 1)
                let dy = readFloat32(data: data, offset: 5)
                moveMouse(dx: Double(dx), dy: Double(dy))
            }
        case 2: // CLICK (count: Int32)
            if data.count >= 5 {
                let count = readInt32(data: data, offset: 1)
                leftClick(clickCount: Int64(count))
            }
        case 3: // SCROLL (dx: Int32, dy: Int32)
            if data.count >= 9 {
                let dx = readInt32(data: data, offset: 1)
                let dy = readInt32(data: data, offset: 5)
                scrollMouse(dx: Int(dx), dy: Int(dy))
            }
        case 4: // RIGHT_CLICK (count: Int32)
            if data.count >= 5 {
                let count = readInt32(data: data, offset: 1)
                rightClick(clickCount: Int64(count))
            }
        case 5: // LEFT_DOWN (count: Int32)
            if data.count >= 5 {
                let count = readInt32(data: data, offset: 1)
                isLeftDown = true
                currentClickCount = Int64(count)
                postClickEvent(type: .leftMouseDown, button: .left, clickCount: Int64(count))
            }
        case 6: // LEFT_UP (count: Int32)
            if data.count >= 5 {
                let count = readInt32(data: data, offset: 1)
                isLeftDown = false
                postClickEvent(type: .leftMouseUp, button: .left, clickCount: Int64(count))
                currentClickCount = 1
            }
        case 7: // GESTURE (String payload)
            if data.count > 1 {
                if let payload = String(data: data.advanced(by: 1), encoding: .utf8) {
                    processStringMessage("GESTURE," + payload, from: connection)
                }
            }
        case 8: // PING
            sendPong(to: connection)
        default:
            break
        }
    }

    private func processStringMessage(_ message: String, from connection: NWConnection) {
        let components = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
        guard !components.isEmpty else { return }

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
            currentClickCount = clickCount
            postClickEvent(type: .leftMouseDown, button: .left, clickCount: clickCount)
        case "LEFT_UP":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            isLeftDown = false
            postClickEvent(type: .leftMouseUp, button: .left, clickCount: clickCount)
            currentClickCount = 1
        case "RIGHT_CLICK":
            let clickCount = components.count >= 2 ? Int64(components[1]) ?? 1 : 1
            rightClick(clickCount: clickCount)
        default:
            break
        }
    }

    private func readFloat32(data: Data, offset: Int) -> Float32 {
        var value: Float32 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset+4) }
        return value
    }

    private func readInt32(data: Data, offset: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset+4) }
        return value
    }

    private func moveMouse(dx: Double, dy: Double) {
        movePacketCount += 1

        // Periodically sync with real OS position to prevent long-term drift
        if movePacketCount % 30 == 0 {
            lastKnownMousePos = nil
        }

        let basePos: CGPoint
        if let lastPos = lastKnownMousePos {
            basePos = lastPos
        } else {
            basePos = CGEvent(source: nil)?.location ?? .zero
        }

        var newX = basePos.x + CGFloat(dx)
        var newY = basePos.y + CGFloat(dy)
        let targetPoint = CGPoint(x: newX, y: newY)

        // Check if this point is on any screen
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(targetPoint, 1, &displayID, &count)

        if count == 0 {
            // Off-screen! Clamp to the boundary of the current screen to prevent "stickiness"
            var currentDisplayID: CGDirectDisplayID = 0
            CGGetDisplaysWithPoint(basePos, 1, &currentDisplayID, &count)
            let bounds = CGDisplayBounds(count > 0 ? currentDisplayID : CGMainDisplayID())

            newX = max(bounds.origin.x, min(newX, bounds.origin.x + bounds.width - 1))
            newY = max(bounds.origin.y, min(newY, bounds.origin.y + bounds.height - 1))
        }

        let finalPoint = CGPoint(x: newX, y: newY)
        lastKnownMousePos = finalPoint

        let eventType: CGEventType = isLeftDown ? .leftMouseDragged : .mouseMoved
        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: finalPoint, mouseButton: .left) else { return }

        if isLeftDown {
            moveEvent.setIntegerValueField(.mouseEventClickState, value: currentClickCount)
        }

        moveEvent.post(tap: .cghidEventTap)

        // Edge Detection
        var edgeDisplayID: CGDirectDisplayID = 0
        var edgeCount: UInt32 = 0
        CGGetDisplaysWithPoint(finalPoint, 1, &edgeDisplayID, &edgeCount)
        let screenRect = (edgeCount > 0) ? CGDisplayBounds(edgeDisplayID) : CGDisplayBounds(CGMainDisplayID())
        let relY = finalPoint.y - screenRect.origin.y

        if relY <= 2 {
            if !isAtTopEdge {
                isAtTopEdge = true
                triggerSystemEvent(keyCode: 120, modifier: "control")
            }
        } else if isAtTopEdge && relY > 20 {
            isAtTopEdge = false
            if !isLeftDown { triggerSystemEvent(keyCode: 53, modifier: "none") }
        }

        if relY >= screenRect.height - 2 {
            if !isAtBottomEdge {
                isAtBottomEdge = true
                gestureQueue.asyncAfter(deadline: .now() + 0.1) {
                    self.triggerSystemEvent(keyCode: 99, modifier: "control")
                }
            }
        } else if isAtBottomEdge && relY < screenRect.height - 40 {
            isAtBottomEdge = false
            if !isLeftDown { triggerSystemEvent(keyCode: 53, modifier: "none") }
        }
    }

    private func postClickEvent(type: CGEventType, button: CGMouseButton, clickCount: Int64 = 1) {
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentLoc, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }

    private func scrollMouse(dx: Int, dy: Int) {
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
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

    private func executeGesture(type: String, modifier: String) {
        var keyCode: Int?
        switch type {
        case "swipe_up": keyCode = 126
        case "swipe_down": keyCode = 125
        case "swipe_left": keyCode = 123
        case "swipe_right": keyCode = 124
        default: break
        }
        if let code = keyCode { triggerSystemEvent(keyCode: code, modifier: modifier) }
    }

    private func triggerSystemEvent(keyCode: Int, modifier: String) {
        gestureQueue.async {
            let mod = modifier.lowercased().trimmingCharacters(in: .whitespaces)
            var scriptSource = "tell application \"System Events\" to key code \(keyCode)"
            if !mod.isEmpty && mod != "none" { scriptSource += " using \(mod) down" }
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&error)
            }
        }
    }

    private func sendPong(to connection: NWConnection) {
        let computerName = Host.current().localizedName ?? "Mac"
        let pongData = "PONG,\(computerName)".data(using: .utf8)
        connection.send(content: pongData, completion: .contentProcessed({ _ in }))
    }
}

let server = MacRemoteServer()
server.start()
