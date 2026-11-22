import Foundation
import Darwin

/// 极简本地静态服务器。
///
/// 把内嵌的 index.html 以 http://127.0.0.1:<port> 的形式提供给 WKWebView，
/// 而不是用 file:// 加载。这样 localStorage 有稳定 origin、navigator.clipboard
/// 处于安全上下文、fetch 调用外部 AI 接口也与真实浏览器一致。
final class LocalWebServer {

    enum ServerError: Error {
        case socketFailed
        case bindFailed
        case listenFailed
    }

    private let root: URL
    private let queue = DispatchQueue(label: "com.fitnessplan.localweb", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var active = false
    private(set) var port: UInt16 = 0

    init(root: URL) {
        self.root = root
    }

    var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    /// 固定端口。localStorage 按 origin（协议+主机+**端口**）隔离，
    /// 端口每次随机变化会让上次保存的数据完全读不到，所以端口必须在多次启动间保持稳定。
    static let defaultPort: UInt16 = 8765
    private static let portKey = "miaoFitness_local_port"

    func start() throws {
        // 优先复用上次成功使用的端口，其次用固定默认端口；两者都失败才退回系统分配。
        // 即使偶发端口冲突，原生 state.json 备份也会在页面加载前注入恢复，数据不会丢。
        let saved = UInt16(UserDefaults.standard.integer(forKey: Self.portKey))
        var candidates: [UInt16] = saved > 0 ? [saved, Self.defaultPort] : [Self.defaultPort]
        var seen = Set<UInt16>()
        candidates = candidates.filter { seen.insert($0).inserted }

        var fd: Int32 = -1
        for candidate in candidates {
            if let bound = try? bindSocket(desiredPort: candidate) {
                fd = bound
                break
            }
        }
        if fd < 0 {
            fd = try bindSocket(desiredPort: 0) // 由系统分配空闲端口
        }
        listenFD = fd
        guard listen(fd, 16) == 0 else { throw ServerError.listenFailed }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { throw ServerError.bindFailed }
        port = UInt16(bigEndian: bound.sin_port)
        // 记住本次端口，下次启动优先复用 → origin 长期稳定
        UserDefaults.standard.set(Int(port), forKey: Self.portKey)

        active = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func bindSocket(desiredPort: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                       socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = desiredPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }
        return fd
    }

    func stop() {
        active = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    deinit {
        stop()
    }

    private func acceptLoop() {
        while active {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listenFD, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if !active { break }
                continue
            }
            serve(client)
            close(client)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var request = Data()
        while request.count < 128 * 1024 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if count <= 0 { break }
            request.append(contentsOf: buffer[0..<count])
            if request.range(of: Data([13, 10, 13, 10])) != nil { break }
        }

        guard !request.isEmpty,
              let text = String(data: request, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first else { return }

        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        guard method == "GET" || method == "HEAD" else {
            writeResponse(fd, status: "405 Method Not Allowed",
                          mime: "text/plain; charset=utf-8", body: Data())
            return
        }

        let rawPath = target.split(separator: "?").first.map(String.init) ?? "/"
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        var relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        if relative.isEmpty { relative = "index.html" }

        let normalized = (relative as NSString).standardizingPath
        guard normalized != "..",
              !normalized.hasPrefix("../"),
              !normalized.hasPrefix("/") else {
            writeResponse(fd, status: "403 Forbidden",
                          mime: "text/plain; charset=utf-8", body: Data("forbidden".utf8))
            return
        }

        let file = root.appendingPathComponent(normalized)
        guard let data = try? Data(contentsOf: file) else {
            writeResponse(fd, status: "404 Not Found",
                          mime: "text/plain; charset=utf-8", body: Data("not found".utf8))
            return
        }
        writeResponse(fd, status: "200 OK", mime: mimeType(for: file.path),
                      body: method == "HEAD" ? Data() : data, contentLength: data.count)
    }

    private func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm":    return "text/html; charset=utf-8"
        case "js", "mjs":      return "application/javascript; charset=utf-8"
        case "css":            return "text/css; charset=utf-8"
        case "json":           return "application/json; charset=utf-8"
        case "png":            return "image/png"
        case "jpg", "jpeg":    return "image/jpeg"
        case "gif":            return "image/gif"
        case "svg":            return "image/svg+xml"
        case "ico":            return "image/x-icon"
        case "woff2":          return "font/woff2"
        default:               return "application/octet-stream"
        }
    }

    private func writeResponse(
        _ fd: Int32,
        status: String,
        mime: String,
        body: Data,
        contentLength: Int? = nil
    ) {
        let length = contentLength ?? body.count
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(mime)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = write(fd, base.advanced(by: sent), raw.count - sent)
                if written <= 0 { break }
                sent += written
            }
        }
    }
}
