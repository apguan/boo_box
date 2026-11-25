import Darwin
import Foundation
@preconcurrency import Virtualization

enum MicroVMError: LocalizedError {
    case virtualizationUnsupported
    case missingGuestAssets(String)
    case missingAttachBinary(String)
    case rootfsCloneFailed(Int32)
    case invalidConfiguration(String)
    case socketSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .virtualizationUnsupported:
            return "Apple Virtualization.framework is not supported on this Mac."
        case .missingGuestAssets(let detail):
            return "Missing Linux guest image assets (\(detail)). Run scripts/build-guest-image.sh."
        case .missingAttachBinary(let path):
            return "Missing boobox-attach helper at \(path)."
        case .rootfsCloneFailed(let code):
            return "Failed to APFS-clone VM rootfs (errno \(code))."
        case .invalidConfiguration(let detail):
            return "Invalid VM configuration: \(detail)"
        case .socketSetupFailed(let detail):
            return "Failed to open VM PTY socket: \(detail)"
        }
    }
}

struct GuestAssets {
    let kernelURL: URL
    let baseRootfsURL: URL
    let attachBinaryURL: URL
}

enum VMState: Equatable, Sendable {
    case booting
    case provisioning
    case running
    case stopped
    case failed(String)
}

/// Manages one live Apple Silicon arm64 Linux microVM backed by Virtualization.framework.
/// Accepts multiple concurrent PTY attachments over a local Unix socket (`socketPath`)
/// and multiplexes each attachment onto a dedicated guest vsock connection (port 5123).
final class SandboxVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let id: UUID
    let instanceDir: URL
    let rootfsURL: URL
    let socketPath: String

    private let vmQueue: DispatchQueue
    private let acceptQueue: DispatchQueue
    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var consoleReadHandle: FileHandle?
    private var listenFD: Int32 = -1
    private var isStopped = false
    private let bootStart = CFAbsoluteTimeGetCurrent()
    private(set) var isReady = false
    private let overrides: SandboxOverrideConfig
    private var hasSharedHostMount = false
    private var isOfflineMode = false
    private(set) var currentState: VMState = .booting
    var onStateChange: (@MainActor @Sendable (VMState) -> Void)?
    var onBootReady: (@MainActor @Sendable (Double) -> Void)?

    private var consoleLog = ""
    private let logLock = NSLock()
    private static let guestPTYPort: UInt32 = 5123

    init(id: UUID, assets: GuestAssets, overrides: SandboxOverrideConfig = .default) throws {
        self.id = id
        self.overrides = overrides
        self.vmQueue = DispatchQueue(label: "dev.boo-box.vm.\(id.uuidString)")
        self.acceptQueue = DispatchQueue(label: "dev.boo-box.vm-accept.\(id.uuidString)", qos: .userInitiated)

        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boo_box/vms", isDirectory: true)
        self.instanceDir = cachesBase.appendingPathComponent(id.uuidString, isDirectory: true)
        self.rootfsURL = instanceDir.appendingPathComponent("rootfs.ext4")

        // Keep Unix socket path short (<104 bytes limit on macOS sockaddr_un)
        let shortID = id.uuidString.prefix(12).lowercased()
        self.socketPath = "/tmp/boobox-\(shortID).sock"

        super.init()

        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)

        // Instant zero-copy APFS clone of base ext4 rootfs
        _ = try? FileManager.default.removeItem(at: rootfsURL)
        let rc = clonefile(assets.baseRootfsURL.path, rootfsURL.path, 0)
        if rc != 0 {
            // Fallback to regular copy if source/dest are on different volumes
            do {
                try FileManager.default.copyItem(at: assets.baseRootfsURL, to: rootfsURL)
            } catch {
                throw MicroVMError.rootfsCloneFailed(errno)
            }
        }

        try startUnixSocketListener()
        try configureAndStartVM(kernelURL: assets.kernelURL)
    }

    deinit {
        stopSync()
    }

    private func emitState(_ state: VMState) {
        logLock.lock()
        currentState = state
        logLock.unlock()
        let cb = onStateChange
        Task { @MainActor in
            cb?(state)
        }
    }

    // MARK: - VZVirtualMachine Configuration & Boot

    private func configureAndStartVM(kernelURL: URL) throws {
        let cfg = VZVirtualMachineConfiguration()

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw init=/sbin/sbox-init quiet loglevel=3"
        cfg.bootLoader = bootLoader

        let vmCfg = BooBoxConfigManager.currentSnapshot().applying(overrides: overrides).privateVM
        cfg.cpuCount = vmCfg.clampedCPUCount
        cfg.memorySize = UInt64(vmCfg.clampedMemoryMB) * 1024 * 1024
        // Rootfs block device (APFS-cloned ext4)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: rootfsURL, readOnly: false)
        cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Vsock device for multi-PTY multiplexing
        cfg.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Optional NAT network device (omitted in Offline mode for pure hypervisor air-gap)
        self.isOfflineMode = (vmCfg.networkMode == .offline)
        if vmCfg.networkMode == .nat {
            let netDevice = VZVirtioNetworkDeviceConfiguration()
            netDevice.attachment = VZNATNetworkDeviceAttachment()
            cfg.networkDevices = [netDevice]
        } else {
            cfg.networkDevices = []
        }

        // Optional opted-in VirtioFS host folder share (mounted at /mnt/host inside Linux guest)
        if let sharedURL = vmCfg.resolvedSharedHostURL {
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "boobox_host")
            let sharedDir = VZSharedDirectory(url: sharedURL, readOnly: vmCfg.sharedHostReadOnly)
            fsDevice.share = VZSingleDirectoryShare(directory: sharedDir)
            cfg.directorySharingDevices = [fsDevice]
            self.hasSharedHostMount = true
        } else {
            self.hasSharedHostMount = false
        }
        // Entropy device
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Serial console capture for boot readiness + error diagnostics
        let consolePipe = Pipe()
        let serialCfg = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialCfg.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: consolePipe.fileHandleForWriting
        )
        cfg.serialPorts = [serialCfg]
        self.consoleReadHandle = consolePipe.fileHandleForReading

        do {
            try cfg.validate()
        } catch {
            throw MicroVMError.invalidConfiguration(error.localizedDescription)
        }

        observeConsole(consolePipe.fileHandleForReading)

        emitState(.booting)

        nonisolated(unsafe) let safeCfg = cfg
        vmQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            let machine = VZVirtualMachine(configuration: safeCfg, queue: self.vmQueue)
            machine.delegate = self
            self.vm = machine
            self.socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice

            machine.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.emitState(.running)
                case .failure(let error):
                    self.emitState(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func observeConsole(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else {
                fh.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                self.logLock.lock()
                self.consoleLog.append(text)
                if self.consoleLog.count > 8192 {
                    self.consoleLog = String(self.consoleLog.suffix(4096))
                }
                let ready = text.contains("BOOBOX_READY")
                if ready {
                    self.isReady = true
                }
                self.logLock.unlock()

                if ready {
                    let bootMs = (CFAbsoluteTimeGetCurrent() - self.bootStart) * 1000.0
                    let cb = self.onBootReady
                    Task { @MainActor in
                        cb?(bootMs)
                    }
                    self.runConfiguredProvisioningIfNeeded()
                }
            }
        }
    }

    /// Runs configured startup script and optional opted-in env vars inside a fresh Private VM
    /// over an internal vsock session (zero host filesystem mounts required).
    private func runConfiguredProvisioningIfNeeded() {
        let setup = BooBoxConfigManager.currentSnapshot().applying(overrides: overrides).ephemeralSetup
        let customScript = setup.privateVMSetupScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let vmEnvVars = setup.injectEnvIntoPrivateVM ? setup.cleanedEnvVars : []
        guard hasSharedHostMount || !customScript.isEmpty || !vmEnvVars.isEmpty else { return }

        var scriptLines: [String] = [
            "#!/bin/sh",
            "exec >/var/log/boobox-setup.log 2>&1",
            "echo '[boo_box] starting private vm provisioning'",
        ]
        if hasSharedHostMount {
            scriptLines.append("mkdir -p /mnt/host && mount -t virtiofs boobox_host /mnt/host 2>/dev/null || true")
        }
        if !vmEnvVars.isEmpty {
            let envBody = vmEnvVars.map { pair in
                let escaped = pair.value.replacingOccurrences(of: "'", with: "'\\''")
                return "export \(pair.key)='\(escaped)'"
            }.joined(separator: "\n") + "\n"
            let envB64 = Data(envBody.utf8).base64EncodedString()
            scriptLines.append("echo '\(envB64)' | base64 -d > /root/.boobox-env.sh && chmod 600 /root/.boobox-env.sh")
            scriptLines.append("grep -q '.boobox-env.sh' /root/.zshrc 2>/dev/null || printf '\\n[ -f /root/.boobox-env.sh ] && source /root/.boobox-env.sh\\n' >> /root/.zshrc")
            scriptLines.append(". /root/.boobox-env.sh")
        }
        if !customScript.isEmpty {
            if !isOfflineMode {
                scriptLines.append("for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ip route 2>/dev/null | grep -q default && break; sleep 0.4; done")
            }
            scriptLines.append(customScript)
        }
        scriptLines.append("touch /var/lib/boobox-setup.done")
        scriptLines.append("echo '[boo_box] setup complete'")
        let fullScript = scriptLines.joined(separator: "\n") + "\n"
        let b64 = Data(fullScript.utf8).base64EncodedString()
        let command = "echo '\(b64)' | base64 -d > /tmp/.boobox-prov.sh && sh /tmp/.boobox-prov.sh; rm -f /tmp/.boobox-prov.sh; exit\n"

        emitState(.provisioning)
        vmQueue.async { [weak self] in
            guard let self, !self.isStopped, let sockDev = self.socketDevice else { return }
            sockDev.connect(toPort: Self.guestPTYPort) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure:
                    self.emitState(.running)
                case .success(let conn):
                    let fd = conn.fileDescriptor
                    nonisolated(unsafe) let retainedConn = conn
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        defer { _ = retainedConn }
                        let handshake = "COLS=80 ROWS=24 TERM=dumb CWD=/root\n"
                        Self.sendRawBytes(fd: fd, data: Data(handshake.utf8))
                        Self.sendFramedData(fd: fd, payload: Data(command.utf8))
                        // Wait until guest shell exits (EOF or MSG_EXIT frame)
                        var buf = [UInt8](repeating: 0, count: 1024)
                        while true {
                            let n = Darwin.read(fd, &buf, buf.count)
                            if n <= 0 { break }
                        }
                        if let self, !self.isStopped {
                            self.emitState(.running)
                        }
                    }
                }
            }
        }
    }

    private static func sendRawBytes(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = Darwin.write(fd, base.advanced(by: off), data.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private static func sendFramedData(fd: Int32, payload: Data) {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(0x01) // MSG_DATA
        var beLen = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &beLen) { frame.append(contentsOf: $0) }
        frame.append(payload)
        sendRawBytes(fd: fd, data: frame)
    }

    // MARK: - Local Unix Socket Multiplexer -> Guest Vsock Port 5123

    private func startUnixSocketListener() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MicroVMError.socketSetupFailed("socket() errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count < maxLen else {
            close(fd)
            throw MicroVMError.socketSetupFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in utf8.enumerated() {
                raw[i] = b
            }
            raw[utf8.count] = 0
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            close(fd)
            throw MicroVMError.socketSetupFailed("bind(\(socketPath)) errno \(err)")
        }

        chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw MicroVMError.socketSetupFailed("listen() errno \(err)")
        }

        self.listenFD = fd

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFD: fd)
        }
    }

    private func runAcceptLoop(listenFD: Int32) {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            // Prevent SIGPIPE from killing host app if a client disconnects mid-write
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            bridgeClientToGuest(clientFD: clientFD, attemptsRemaining: 240)
        }
    }

    private func bridgeClientToGuest(clientFD: Int32, attemptsRemaining: Int) {
        vmQueue.async { [weak self] in
            guard let self, !self.isStopped else {
                close(clientFD)
                return
            }
            guard let sockDev = self.socketDevice, self.vm?.state == .running else {
                if attemptsRemaining > 0 {
                    self.vmQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                        self?.bridgeClientToGuest(clientFD: clientFD, attemptsRemaining: attemptsRemaining - 1)
                    }
                } else {
                    close(clientFD)
                }
                return
            }

            sockDev.connect(toPort: Self.guestPTYPort) { [weak self] result in
                guard let self else {
                    close(clientFD)
                    return
                }
                switch result {
                case .success(let connection):
                    self.splice(clientFD: clientFD, vsockConnection: connection)
                case .failure:
                    if attemptsRemaining > 0 && !self.isStopped {
                        self.vmQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                            self?.bridgeClientToGuest(clientFD: clientFD, attemptsRemaining: attemptsRemaining - 1)
                        }
                    } else {
                        close(clientFD)
                    }
                }
            }
        }
    }

    /// Bidirectional full-duplex relay between boobox-attach Unix fd and guest VZVirtioSocketConnection.
    /// Keeps `vsockConnection` strongly retained for the lifetime of both relay directions.
    private func splice(clientFD: Int32, vsockConnection: VZVirtioSocketConnection) {
        let guestFD = vsockConnection.fileDescriptor
        var one: Int32 = 1
        setsockopt(guestFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let group = DispatchGroup()

        // Client (Ghostty PTY shim) -> Guest VM
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            Self.pump(from: clientFD, to: guestFD)
            shutdown(guestFD, SHUT_WR)
            group.leave()
        }

        // Guest VM -> Client (Ghostty PTY shim)
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            Self.pump(from: guestFD, to: clientFD)
            shutdown(clientFD, SHUT_WR)
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            close(clientFD)
            // Keep vsockConnection alive until both directions finish, then close cleanly
            withExtendedLifetime(vsockConnection) {
                vsockConnection.close()
            }
        }
    }

    private static func pump(from srcFD: Int32, to dstFD: Int32) {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(srcFD, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = buf.withUnsafeBytes { ptr in
                    Darwin.write(dstFD, ptr.baseAddress!.advanced(by: written), n - written)
                }
                if w < 0 {
                    if errno == EINTR { continue }
                    return
                }
                written += w
            }
        }
    }

    // MARK: - Lifecycle / Teardown

    func stop() {
        stopSync()
    }

    private func stopSync() {
        guard !isStopped else { return }
        isStopped = true

        consoleReadHandle?.readabilityHandler = nil
        consoleReadHandle = nil

        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)

        nonisolated(unsafe) let machine = vm
        let dir = instanceDir
        vmQueue.async { [weak self] in
            if let machine, machine.canStop {
                machine.stop { _ in
                    try? FileManager.default.removeItem(at: dir)
                }
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
            self?.vm = nil
            self?.socketDevice = nil
        }
        emitState(.stopped)
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        emitState(.stopped)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        emitState(.failed(error.localizedDescription))
    }
}

@MainActor
final class MicroVMManager {
    static let shared = MicroVMManager()

    private var vms: [UUID: SandboxVM] = [:]
    private var warmVM: SandboxVM?

    private init() {
        // Clean up any stale sockets/temp VMs from prior crashed launches
        cleanupStaleTempFiles()
    }

    func resolveGuestAssets() throws -> GuestAssets {
        guard VZVirtualMachine.isSupported else {
            throw MicroVMError.virtualizationUnsupported
        }

        let fm = FileManager.default
        let vmDirCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("vm", isDirectory: true),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/vm", isDirectory: true),
        ]

        var foundVMDir: URL?
        for case let dir? in vmDirCandidates {
            let k = dir.appendingPathComponent("vmlinux-arm64")
            let r = dir.appendingPathComponent("rootfs.ext4")
            if fm.fileExists(atPath: k.path) && fm.fileExists(atPath: r.path) {
                foundVMDir = dir
                break
            }
        }

        guard let vmDir = foundVMDir else {
            throw MicroVMError.missingGuestAssets("vmlinux-arm64 / rootfs.ext4 not found in app bundle")
        }

        let attachCandidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boobox-attach"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/boobox-attach"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/release/boobox-attach"),
        ]

        guard let attachURL = attachCandidates.compactMap({ $0 }).first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw MicroVMError.missingAttachBinary("boobox-attach")
        }

        return GuestAssets(
            kernelURL: vmDir.appendingPathComponent("vmlinux-arm64"),
            baseRootfsURL: vmDir.appendingPathComponent("rootfs.ext4"),
            attachBinaryURL: attachURL
        )
    }

    func startVM(
        for sessionID: UUID,
        overrides: SandboxOverrideConfig = .default
    ) throws -> (vm: SandboxVM, attachBinary: URL, fromWarmPool: Bool) {
        let assets = try resolveGuestAssets()

        // Only pop from the global warm pool when the VM uses default global compute/network/mount settings
        if !overrides.hasPrivateVMOverrides, let prewarmed = warmVM {
            warmVM = nil
            vms[sessionID] = prewarmed
            scheduleWarmPoolReplenish()
            return (prewarmed, assets.attachBinaryURL, true)
        }

        let vm = try SandboxVM(id: sessionID, assets: assets, overrides: overrides)
        vms[sessionID] = vm
        if !overrides.hasPrivateVMOverrides {
            scheduleWarmPoolReplenish()
        }
        return (vm, assets.attachBinaryURL, false)
    }

    /// Pre-boots 1 idle arm64 Linux microVM in the background (~35–45 MB idle RSS)
    /// so the next ⌘T or Reset pops an already-running VM in <1 ms.
    func scheduleWarmPoolReplenish() {
        guard BooBoxConfigManager.currentSnapshot().privateVM.prewarmPool else { return }
        guard warmVM == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.warmVM == nil, BooBoxConfigManager.currentSnapshot().privateVM.prewarmPool else { return }
            guard let assets = try? self.resolveGuestAssets() else { return }
            if let standby = try? SandboxVM(id: UUID(), assets: assets) {
                self.warmVM = standby
            }
        }
    }

    /// Tears down any pre-warmed Private VM so the next Private VM uses updated setup packages/scripts.
    func invalidateWarmPool() {
        warmVM?.stop()
        warmVM = nil
    }

    func vm(for sessionID: UUID) -> SandboxVM? {
        vms[sessionID]
    }

    func destroyVM(for sessionID: UUID) {
        if let vm = vms.removeValue(forKey: sessionID) {
            vm.stop()
        }
    }

    func shutdownAll() {
        warmVM?.stop()
        warmVM = nil
        for vm in vms.values {
            vm.stop()
        }
        vms.removeAll()
    }

    private func cleanupStaleTempFiles() {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: "/tmp") {
            for name in entries where name.hasPrefix("boobox-") && name.hasSuffix(".sock") {
                unlink("/tmp/\(name)")
            }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let vmsDir = caches.appendingPathComponent("boo_box/vms", isDirectory: true)
            try? fm.removeItem(at: vmsDir)
        }
    }
}
