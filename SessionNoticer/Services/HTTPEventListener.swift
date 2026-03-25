import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "http")

class HTTPEventListener {
    private var listener: NWListener?
    private let port: UInt16
    var onEvent: ((HookEvent) -> Void)?

    init(port: UInt16 = 9999) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.error("Failed to create listener on port \(self.port): \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("HTTP listener ready on port \(self.port)")
            case .failed(let error):
                logger.error("HTTP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            defer { connection.cancel() }

            guard let data, error == nil else {
                self?.sendResponse(connection: connection, status: 400, body: "Bad request")
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                self?.sendResponse(connection: connection, status: 400, body: "Invalid encoding")
                return
            }

            guard request.hasPrefix("POST /event") else {
                self?.sendResponse(connection: connection, status: 404, body: "Not found")
                return
            }

            let parts = request.components(separatedBy: "\r\n\r\n")
            guard parts.count >= 2, let jsonData = parts[1].data(using: .utf8) else {
                self?.sendResponse(connection: connection, status: 400, body: "No body")
                return
            }

            guard let event = try? JSONDecoder().decode(HookEvent.self, from: jsonData) else {
                logger.warning("Failed to parse event JSON from HTTP")
                self?.sendResponse(connection: connection, status: 400, body: "Invalid JSON")
                return
            }

            logger.info("Received remote event: \(event.event.rawValue) from \(event.hostname ?? "unknown")")
            self?.sendResponse(connection: connection, status: 200, body: "OK")
            DispatchQueue.main.async {
                self?.onEvent?(event)
            }
        }
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .idempotent)
    }
}
