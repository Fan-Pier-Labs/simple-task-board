import Foundation
import Network

/// A very small HTTP/1.1 server that listens on this machine only and hands each request to a
/// handler. One request per connection; that is all the API needs.
public final class LocalAPIServer {
    public enum State: Equatable {
        case starting
        case listening(port: Int)
        case failed(String)
        case stopped
    }

    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 1024 * 1024

    private let listener: NWListener
    private let handler: (APIRequest) -> APIResponse
    /// Requests are handled one at a time, so two writers never race on a task file.
    private let queue = DispatchQueue(label: "taskboard.api")
    private let onState: (State) -> Void

    /// `port` 0 lets the system pick one, which tests use.
    public init(port: Int, handler: @escaping (APIRequest) -> APIResponse, onState: @escaping (State) -> Void = { _ in }) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: nothing off this machine can reach it.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        )
        self.listener = try NWListener(using: parameters)
        self.handler = handler
        self.onState = onState
    }

    public func start() {
        onState(.starting)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState(.listening(port: Int(self.listener.port?.rawValue ?? 0)))
            case .failed(let error):
                self.onState(.failed(Self.describe(error)))
                self.listener.cancel()
            case .waiting(let error):
                self.onState(.failed(Self.describe(error)))
            case .cancelled:
                self.onState(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "The port is already in use by another program."
        }
        return error.localizedDescription
    }

    // MARK: - One connection

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch Self.parse(buffer) {
            case .request(let request):
                self.send(self.handler(request), on: connection)
            case .invalid(let status, let message):
                self.send(.error(status, message), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: APIResponse, on connection: NWConnection) {
        let body = response.body
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        default: return "Error"
        }
    }

    // MARK: - Reading a request

    enum Parsed {
        case incomplete
        case request(APIRequest)
        case invalid(Int, String)
    }

    /// Turns the bytes received so far into a request, once all of it has arrived.
    static func parse(_ buffer: Data) -> Parsed {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maximumHeaderBytes ? .invalid(413, "The request headers are too large.") : .incomplete
        }
        let lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(400, "That is not an HTTP request.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, headers["transfer-encoding"] == nil else {
            return .invalid(400, "Send the body with a Content-Length header.")
        }
        guard length <= maximumBodyBytes else { return .invalid(413, "The request body is too large.") }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(APIRequest(method: String(requestLine[0]), path: path, headers: headers, body: body))
    }
}
