import Darwin
import Foundation

// SFTP 프로토콜 버전 3 클라이언트 (draft-ietf-secsh-filexfer-02, OpenSSH 가 쓰는 버전)
//
// 전송로(SFTPTransport)는 표준 입출력으로 SFTP 패킷을 주고받는 프로세스다.
//   - 실제 접속: `ssh -s <호스트> sftp`  (OpenSSH 인증·설정·연결 재사용을 그대로 쓴다)
//   - 테스트:    `/usr/libexec/sftp-server` (로컬 파일 시스템)

/// 원격 파일 하나
struct SFTPEntry: Identifiable, Hashable {
    var name: String
    var path: String
    var size: UInt64
    var permissions: UInt32
    var modified: Date?
    var isDirectory: Bool
    var isSymlink: Bool

    var id: String { path }
}

struct SFTPAttributes: Equatable {
    var size: UInt64?
    var permissions: UInt32?
    var modified: Date?

    var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }
}

enum SFTPError: LocalizedError, Equatable {
    case status(code: UInt32, message: String)
    case connectionLost(String)
    case protocolError(String)
    /// 접속 실패 (사용자가 할 일을 담은 문장)
    case connectionFailed(String)

    static let noSuchFile: UInt32 = 2
    static let permissionDenied: UInt32 = 3

    var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            switch code {
            case 2: return "파일이나 폴더가 없습니다."
            case 3: return "권한이 없습니다."
            case 4: return message.isEmpty ? "작업에 실패했습니다." : "작업에 실패했습니다: \(message)"
            case 8: return "서버가 지원하지 않는 작업입니다."
            default: return message.isEmpty ? "SFTP 오류 (\(code))" : message
            }
        case .connectionLost(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "연결이 끊어졌습니다." : "연결이 끊어졌습니다: \(trimmed)"
        case .protocolError(let detail):
            return "SFTP 통신 오류: \(detail)"
        case .connectionFailed(let message):
            return message
        }
    }
}

// MARK: - 전송로

protocol SFTPTransport: AnyObject {
    /// 서버로 보내는 쪽
    var input: FileHandle { get }
    /// 서버에서 받는 쪽
    var output: FileHandle { get }
    /// 진단용 (ssh 의 오류 메시지 등)
    var errorText: String { get }
    func terminate()
}

/// 프로세스의 표준 입출력을 전송로로 쓴다.
final class ProcessTransport: SFTPTransport {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stderrBuffer = Data()

    var input: FileHandle { stdinPipe.fileHandleForWriting }
    var output: FileHandle { stdoutPipe.fileHandleForReading }
    var errorText: String { lock.withLock { String(decoding: stderrBuffer, as: UTF8.self) } }

    init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.stderrBuffer.append(data)
                if self.stderrBuffer.count > 16_384 { self.stderrBuffer = self.stderrBuffer.suffix(8_192) }
            }
        }
        try process.run()
    }

    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}

// MARK: - 클라이언트

final class SFTPClient {
    private enum PacketType: UInt8 {
        case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7
        case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105
        case extended = 200, extendedReply = 201
    }

    private enum Response {
        case status(UInt32, String)
        case handle(Data)
        case data(Data)
        case name([(name: String, attributes: SFTPAttributes)])
        case attrs(SFTPAttributes)
        case extendedReply
    }

    /// 한 번에 읽고 쓰는 크기와 동시에 보내는 요청 수 (지연이 큰 연결에서도 속도가 나도록)
    static let chunkSize = 32 * 1024
    static let window = 16

    private let transport: SFTPTransport
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Response, Error>] = [:]
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private var closed = false
    private(set) var extensions: [String: String] = [:]

    /// 전송로를 열고 SFTP 초기화(INIT/VERSION)까지 마친다.
    init(transport: SFTPTransport) async throws {
        self.transport = transport
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "dev.myterminal.sftp.reader"
        thread.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { versionContinuation = continuation }
            var payload = Writer()
            payload.u32(3)
            do {
                try write(type: .initialize, id: nil, payload: payload.data)
            } catch {
                lock.withLock { versionContinuation = nil }
                continuation.resume(throwing: error)
            }
        }
    }

    deinit { close() }

    func close() {
        let waiting: [CheckedContinuation<Response, Error>] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        transport.terminate()
        waiting.forEach { $0.resume(throwing: SFTPError.connectionLost("")) }
    }

    // MARK: 경로·목록

    /// 경로를 절대 경로로 바꾼다. "." 은 원격 홈 폴더.
    func realpath(_ path: String) async throws -> String {
        var p = Writer(); p.string(path)
        guard case .name(let names) = try await request(.realpath, p.data), let first = names.first else {
            throw SFTPError.protocolError("realpath 응답 없음")
        }
        return first.name
    }

    func stat(_ path: String) async throws -> SFTPAttributes {
        var p = Writer(); p.string(path)
        guard case .attrs(let attrs) = try await request(.stat, p.data) else { throw SFTPError.protocolError("stat") }
        return attrs
    }

    /// 폴더 안의 항목 ("." ".." 제외). 심볼릭 링크는 가리키는 대상이 폴더인지 확인한다.
    func list(_ path: String) async throws -> [SFTPEntry] {
        var p = Writer(); p.string(path)
        guard case .handle(let handle) = try await request(.opendir, p.data) else {
            throw SFTPError.protocolError("opendir")
        }
        defer { Task { try? await self.closeHandle(handle) } }

        var entries: [SFTPEntry] = []
        while true {
            var r = Writer(); r.bytes(handle)
            let response = try await request(.readdir, r.data, allowEOF: true)
            guard case .name(let names) = response else { break }   // EOF
            for item in names where item.name != "." && item.name != ".." {
                let fullPath = Self.join(path, item.name)
                var entry = SFTPEntry(
                    name: item.name,
                    path: fullPath,
                    size: item.attributes.size ?? 0,
                    permissions: item.attributes.permissions ?? 0,
                    modified: item.attributes.modified,
                    isDirectory: item.attributes.isDirectory,
                    isSymlink: item.attributes.isSymlink)
                if entry.isSymlink, let target = try? await stat(fullPath) {
                    entry.isDirectory = target.isDirectory
                }
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: 변경

    func mkdir(_ path: String) async throws {
        var p = Writer(); p.string(path); p.u32(0)   // 속성 없음
        try await expectOK(.mkdir, p.data)
    }

    func rmdir(_ path: String) async throws {
        var p = Writer(); p.string(path)
        try await expectOK(.rmdir, p.data)
    }

    func remove(_ path: String) async throws {
        var p = Writer(); p.string(path)
        try await expectOK(.remove, p.data)
    }

    /// 이름 바꾸기. 서버가 지원하면 대상이 있어도 바꾸는 posix-rename 을 쓴다.
    func rename(_ from: String, to: String) async throws {
        if extensions["posix-rename@openssh.com"] != nil {
            var p = Writer(); p.string("posix-rename@openssh.com"); p.string(from); p.string(to)
            try await expectOK(.extended, p.data)
        } else {
            var p = Writer(); p.string(from); p.string(to)
            try await expectOK(.rename, p.data)
        }
    }

    /// 폴더를 안의 내용까지 지운다.
    func removeRecursively(_ path: String) async throws {
        let attrs = try await lstat(path)
        guard attrs.isDirectory else { return try await remove(path) }
        for entry in try await list(path) {
            if entry.isDirectory && !entry.isSymlink {
                try await removeRecursively(entry.path)
            } else {
                try await remove(entry.path)
            }
        }
        try await rmdir(path)
    }

    func lstat(_ path: String) async throws -> SFTPAttributes {
        var p = Writer(); p.string(path)
        guard case .attrs(let attrs) = try await request(.lstat, p.data) else { throw SFTPError.protocolError("lstat") }
        return attrs
    }

    // MARK: 전송

    /// 원격 파일을 로컬 파일로 받는다. progress 는 받은 바이트 누계.
    func download(
        _ remotePath: String,
        to localURL: URL,
        progress: @escaping (UInt64) -> Void = { _ in }
    ) async throws {
        let size = try await stat(remotePath).size ?? 0
        let handle = try await open(remotePath, flags: 0x01)   // READ
        defer { Task { try? await self.closeHandle(handle) } }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }

        var received: UInt64 = 0
        var offset: UInt64 = 0
        var reachedEOF = false

        try await withThrowingTaskGroup(of: (UInt64, Data?).self) { group in
            func enqueue() {
                guard !reachedEOF, offset < max(size, 1) || size == 0 && offset == 0 else { return }
                let at = offset
                offset += UInt64(Self.chunkSize)
                group.addTask { (at, try await self.read(handle, offset: at, length: UInt32(Self.chunkSize))) }
            }
            for _ in 0..<Self.window { enqueue() }

            while let (at, data) = try await group.next() {
                try Task.checkCancellation()
                if let data, !data.isEmpty {
                    try Self.write(data, to: file, at: at)
                    received += UInt64(data.count)
                    progress(received)
                    // 크기보다 짧게 읽혔으면 이어서 읽는다 (서버가 나눠 보낸 경우)
                    if data.count < Self.chunkSize, at + UInt64(data.count) < size {
                        let rest = at + UInt64(data.count)
                        group.addTask {
                            (rest, try await self.read(handle, offset: rest, length: UInt32(at + UInt64(Self.chunkSize) - rest)))
                        }
                    }
                } else {
                    reachedEOF = true
                }
                if size > 0 { enqueue() }
            }
        }
    }

    /// 로컬 파일을 원격으로 올린다. 같은 이름이 있으면 덮어쓴다.
    func upload(
        _ localURL: URL,
        to remotePath: String,
        progress: @escaping (UInt64) -> Void = { _ in }
    ) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0

        // WRITE | CREAT | TRUNC, 권한 0644
        var attrs = Writer()
        attrs.u32(0x04); attrs.u32(0o644)
        let handle = try await open(remotePath, flags: 0x02 | 0x08 | 0x10, attributes: attrs.data)
        defer { Task { try? await self.closeHandle(handle) } }

        var sent: UInt64 = 0
        var offset: UInt64 = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            func enqueue() throws {
                guard offset < size else { return }
                let at = offset
                try file.seek(toOffset: at)
                let data = file.readData(ofLength: Self.chunkSize)
                guard !data.isEmpty else { offset = size; return }
                offset += UInt64(data.count)
                group.addTask {
                    try await self.write(handle, offset: at, data: data)
                    return data.count
                }
            }
            for _ in 0..<Self.window { try enqueue() }
            while let count = try await group.next() {
                try Task.checkCancellation()
                sent += UInt64(count)
                progress(sent)
                try enqueue()
            }
        }
    }

    // MARK: 파일 핸들

    private func open(_ path: String, flags: UInt32, attributes: Data = Data([0, 0, 0, 0])) async throws -> Data {
        var p = Writer(); p.string(path); p.u32(flags); p.raw(attributes)
        guard case .handle(let handle) = try await request(.open, p.data) else { throw SFTPError.protocolError("open") }
        return handle
    }

    private func closeHandle(_ handle: Data) async throws {
        var p = Writer(); p.bytes(handle)
        try await expectOK(.close, p.data)
    }

    /// nil = 파일 끝
    private func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        var p = Writer(); p.bytes(handle); p.u64(offset); p.u32(length)
        switch try await request(.read, p.data, allowEOF: true) {
        case .data(let data): return data
        default: return nil
        }
    }

    private func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        var p = Writer(); p.bytes(handle); p.u64(offset); p.bytes(data)
        try await expectOK(.write, p.data)
    }

    private static func write(_ data: Data, to file: FileHandle, at offset: UInt64) throws {
        try file.seek(toOffset: offset)
        try file.write(contentsOf: data)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    // MARK: - 요청과 응답

    private func expectOK(_ type: PacketType, _ payload: Data) async throws {
        _ = try await request(type, payload)
    }

    /// 요청을 보내고 응답을 기다린다. 실패 STATUS 는 오류로 던진다.
    private func request(_ type: PacketType, _ payload: Data, allowEOF: Bool = false) async throws -> Response {
        let response: Response = try await withCheckedThrowingContinuation { continuation in
            let id: UInt32? = lock.withLock {
                if closed { return nil }
                let id = nextID
                nextID &+= 1
                pending[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: SFTPError.connectionLost(transport.errorText))
                return
            }
            do {
                try write(type: type, id: id, payload: payload)
            } catch {
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) {
                    waiting.resume(throwing: SFTPError.connectionLost(transport.errorText))
                }
            }
        }
        if case .status(let code, let message) = response {
            if code == 0 || (code == 1 && allowEOF) { return response }
            throw SFTPError.status(code: code, message: message)
        }
        return response
    }

    private let writeLock = NSLock()

    private func write(type: PacketType, id: UInt32?, payload: Data) throws {
        var body = Writer()
        body.u8(type.rawValue)
        if let id { body.u32(id) }
        body.raw(payload)
        var packet = Writer()
        packet.u32(UInt32(body.data.count))
        packet.raw(body.data)
        try writeLock.withLock { try transport.input.write(contentsOf: packet.data) }
    }

    /// 별도 스레드에서 응답 패킷을 읽어 기다리는 요청에 넘겨준다.
    private func readLoop() {
        let fd = transport.output.fileDescriptor
        while true {
            guard let header = Self.readExactly(fd, 4) else { break }
            let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
            guard length > 0, length < 64 * 1024 * 1024, let body = Self.readExactly(fd, length) else { break }
            handlePacket(body)
        }

        let error = SFTPError.connectionLost(transport.errorText)
        let (waiting, version): ([CheckedContinuation<Response, Error>], CheckedContinuation<Void, Error>?) = lock.withLock {
            closed = true
            defer { pending.removeAll(); versionContinuation = nil }
            return (Array(pending.values), versionContinuation)
        }
        waiting.forEach { $0.resume(throwing: error) }
        version?.resume(throwing: error)
    }

    private func handlePacket(_ body: [UInt8]) {
        var reader = Reader(body)
        do {
            let rawType = try reader.u8()
            if rawType == PacketType.version.rawValue {
                _ = try reader.u32()
                var ext: [String: String] = [:]
                while !reader.isAtEnd { ext[try reader.string()] = try reader.string() }
                let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                    extensions = ext
                    defer { versionContinuation = nil }
                    return versionContinuation
                }
                continuation?.resume()
                return
            }

            let id = try reader.u32()
            let response: Response
            switch PacketType(rawValue: rawType) {
            case .status:
                let code = try reader.u32()
                let message = reader.isAtEnd ? "" : try reader.string()
                response = .status(code, message)
            case .handle:
                response = .handle(try reader.bytes())
            case .data:
                response = .data(try reader.bytes())
            case .name:
                let count = try reader.u32()
                var names: [(String, SFTPAttributes)] = []
                for _ in 0..<count {
                    let name = try reader.string()
                    _ = try reader.string()   // longname (ls -l 형식, 쓰지 않음)
                    names.append((name, try reader.attributes()))
                }
                response = .name(names)
            case .attrs:
                response = .attrs(try reader.attributes())
            case .extendedReply:
                response = .extendedReply
            default:
                return
            }
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            continuation?.resume(returning: response)
        } catch {
            NSLog("[MyTerminal] SFTP 패킷 해석 실패: \(error)")
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + filled, count - filled) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            filled += n
        }
        return buffer
    }
}

// MARK: - 바이트 읽기·쓰기 (빅엔디언)

private struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    mutating func string(_ s: String) { bytes(Data(s.utf8)) }
    mutating func raw(_ d: Data) { data.append(d) }
}

private struct Reader {
    private let buffer: [UInt8]
    private var offset = 0
    init(_ buffer: [UInt8]) { self.buffer = buffer }

    var isAtEnd: Bool { offset >= buffer.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, offset + n <= buffer.count else { throw SFTPError.protocolError("패킷이 짧음") }
        defer { offset += n }
        return buffer[offset..<offset + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func bytes() throws -> Data {
        let length = Int(try u32())
        return Data(try take(length))
    }
    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        var attrs = SFTPAttributes()
        if flags & 0x01 != 0 { attrs.size = try u64() }
        if flags & 0x02 != 0 { _ = try u32(); _ = try u32() }              // uid, gid
        if flags & 0x04 != 0 { attrs.permissions = try u32() }
        if flags & 0x08 != 0 {                                                // atime, mtime
            _ = try u32()
            attrs.modified = Date(timeIntervalSince1970: TimeInterval(try u32()))
        }
        if flags & 0x8000_0000 != 0 {                                         // 확장 속성
            let count = try u32()
            for _ in 0..<count { _ = try string(); _ = try string() }
        }
        return attrs
    }
}
