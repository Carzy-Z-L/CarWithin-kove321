import CoreBluetooth
import CoreImage
import Foundation
import Network
import VideoToolbox

/// 凯越 321RS（思骑出行 ThinkerRide 协议）的输出规格。
/// 仪表候选分辨率取自官方 App `xt1`（ProjectionEncoder）构造函数。
struct ThinkerRideProfile: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let label: String

    static let koveSquare = ThinkerRideProfile(width: 800, height: 800, fps: 30, bitrate: 3_800_000, label: "凯越 321RS 800×800")
    static let koveWide = ThinkerRideProfile(width: 800, height: 640, fps: 30, bitrate: 3_200_000, label: "凯越 800×640")
    static let koveNarrow = ThinkerRideProfile(width: 480, height: 800, fps: 30, bitrate: 2_400_000, label: "凯越 480×800")
    static let koveBand = ThinkerRideProfile(width: 1280, height: 640, fps: 30, bitrate: 5_000_000, label: "凯越 1280×640")

    var encodeWidth: Int { width - width % 2 }
    var encodeHeight: Int { height - height % 2 }
    var title: String { "\(width)×\(height)" }
}

/// 凯越/思骑 BLE 点火：手机作为 BLE 中心设备连接仪表，
/// 订阅 FFE2（仪表→手机 JSON），对仪表心跳 {msg_id:10,item:4,tag:N}
/// 按 `d93.a()`/`ji.b()` 还原的格式回写 FFE1：
/// {"msg_id":11,"time":"yyyy-MM-dd HH:mm:ss","tag":N} + 2 字节校验 + 0x00，
/// 再按 100 字节分包成 [FE 00 00 payload FF]。
final class ThinkerRideBle: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "0000E0FF-3C17-D293-8E48-14FE2E4DA212")
    static let writeUUID = CBUUID(string: "0000FFE1-3C17-D293-8E48-14FE2E4DA212")
    static let notifyUUID = CBUUID(string: "0000FFE2-3C17-D293-8E48-14FE2E4DA212")
    private static let nameHints = ["CQKY", "KOVE", "SQ", "THINKER", "EC-"]

    private let lock = NSLock()
    private var active = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var service: CBService?
    private var buffer = Data()
    private var lastTag: Int?
    private var connectedOnce = false
    private let onLog: (String) -> Void
    private var onConnected: (() -> Void)?

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        super.init()
    }

    func start(onConnected: @escaping () -> Void) {
        stop()
        lock.withLock { active = true; connectedOnce = false }
        self.onConnected = onConnected
        central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "CarWithin.kove.ble", qos: .userInitiated))
    }

    func stop() {
        lock.withLock { active = false }
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central = nil
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        service = nil
        buffer = Data()
    }

    private var isActive: Bool { lock.withLock { active } }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isActive else { return }
        switch central.state {
        case .poweredOn:
            onLog("[凯越] 蓝牙就绪，正在扫描仪表…（请让仪表停在手机互联页面，iPhone 靠近仪表）")
            central.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff: onLog("[凯越] 蓝牙未开启，点火暂停。")
        case .unauthorized: onLog("[凯越] 蓝牙权限被拒绝，请在系统设置中允许。")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isActive, self.peripheral == nil else { return }
        let name = (peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "").uppercased()
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matchesService = advertised.contains { $0.uuidString.uppercased().hasPrefix("E0FF") }
        let matchesName = Self.nameHints.contains { name.hasPrefix($0) }
        guard matchesService || matchesName, RSSI.intValue > -90 else { return }
        onLog("[凯越] 发现仪表 \(name.isEmpty ? peripheral.identifier.uuidString : name)（RSSI \(RSSI.intValue)），连接中…")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isActive else { return }
        onLog("[凯越] 蓝牙已连接，发现服务中…")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onLog("[凯越] 蓝牙连接失败：\(error?.localizedDescription ?? "未知错误")，3 秒后重试")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard isActive else { return }
        self.peripheral = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isActive, let central = self.central, central.state == .poweredOn else { return }
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isActive else { return }
        if let error { onLog("[凯越] 服务发现失败：\(error.localizedDescription)"); scheduleRetry(); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            onLog("[凯越] 未找到 E0FF 服务，3 秒后重试")
            scheduleRetry()
            return
        }
        self.service = service
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isActive else { return }
        if let error { onLog("[凯越] 特征发现失败：\(error.localizedDescription)"); scheduleRetry(); return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.writeUUID: writeCharacteristic = characteristic
            case Self.notifyUUID:
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
        guard notifyCharacteristic != nil else {
            onLog("[凯越] 未找到 FFE2 通知特征，3 秒后重试")
            scheduleRetry()
            return
        }
        onLog("[凯越] 已订阅仪表通知，等待心跳并自动应答…")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { onLog("[凯越] 订阅失败：\(error.localizedDescription)") }
        else if characteristic.uuid == Self.notifyUUID, !connectedOnce {
            connectedOnce = true
            onLog("[凯越] 点火通道就绪（FFE2 已订阅）")
            onConnected?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isActive, characteristic.uuid == Self.notifyUUID, let value = characteristic.value, error == nil else { return }
        buffer.append(value)
        // 仪表推送是换行缩进的明文 JSON，按大括号配对切分。
        while let start = buffer.firstIndex(of: UInt8(ascii: "{")), let end = buffer.firstIndex(of: UInt8(ascii: "}")) {
            guard end > start else { buffer.removeFirst(end - buffer.startIndex + 1); continue }
            let chunk = buffer.subdata(in: start...end)
            buffer.removeFirst(end - buffer.startIndex + 1)
            guard let object = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any] else { continue }
            handle(object)
        }
        if buffer.count > 4096 { buffer = Data() }
    }

    private func handle(_ object: [String: Any]) {
        guard object["msg_id"] as? Int == 10, object["item"] as? Int == 4 else { return }
        guard let tag = object["tag"] as? Int else { return }
        // 源码 BleConnectWrapper.L0() case 4 → c11.f0(tag)：只应答新的 tag。
        guard tag != lastTag else { return }
        lastTag = tag
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let reply = "{\"msg_id\":11,\"time\":\"\(formatter.string(from: Date()))\",\"tag\":\(tag)}"
        send(json: reply)
    }

    func send(json: String) {
        guard let peripheral, let writeCharacteristic else { return }
        let data = Self.encoded(json)
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if maximum >= data.count, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: writeCharacteristic, type: .withoutResponse)
        } else {
            var offset = 0
            let chunkLimit = max(20, min(maximum, 512))
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + chunkLimit, data.count))
                peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
                offset += chunk.count
            }
        }
    }

    /// 复刻思骑 WriteThread（d93.a + ji.b/l）：JSON + 校验 2 字节 + 0x00，按 100 字节分包 [FE 00 00 payload FF]。
    static func encoded(_ json: String) -> Data {
        let payload = Array((json + "\u{0000}").utf8)
        let sum = payload.reduce(0) { ($0 + Int($1)) & 0xFF }
        var wire = payload
        wire.removeLast()
        wire.append(UInt8(((sum & 0xF0) >> 4) | 0x80))
        wire.append(UInt8((sum & 0x0F) | 0x80))
        wire.append(0)
        var out = Data()
        var offset = 0
        while offset < wire.count {
            let chunk = Array(wire[offset..<min(offset + 100, wire.count)])
            var packet = [UInt8](repeating: 0, count: chunk.count + 4)
            packet[0] = 0xFE
            for (index, byte) in chunk.enumerated() { packet[3 + index] = byte }
            packet[chunk.count + 3] = 0xFF
            out.append(Data(packet))
            offset += 100
        }
        return out
    }
}

/// 凯越/思骑 WiFi 数据面：手机监听 17818（控制/JSON）与 15456（视频），
/// 仪表连上仪表热点后会主动回连。视频先发 69 字节会话头（xt1.m()），随后裸 H.264。
final class ThinkerRideOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "kove321") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, profile: ThinkerRideProfile,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, profile: profile, onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    // MARK: - 会话

    private final class Session: @unchecked Sendable {
        static let controlPort: UInt16 = 17818
        static let videoPort: UInt16 = 15456

        let queue: DispatchQueue
        let profile: ThinkerRideProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void

        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?
        private var encodeWidth: Int
        private var encodeHeight: Int
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        private let ble: ThinkerRideBle
        private var controlListener: NWListener?
        private var videoListener: NWListener?
        private var controlConnection: NWConnection?
        private var videoConnection: NWConnection?
        private var controlBuffer = Data()
        private var videoReady = false
        private var heartbeatTimer: DispatchSourceTimer?
        private var heartbeatToggle = false

        init(queue: DispatchQueue, profile: ThinkerRideProfile, onState: @escaping (String) -> Void,
             onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.profile = profile
            encodeWidth = profile.encodeWidth
            encodeHeight = profile.encodeHeight
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            ble = ThinkerRideBle(onLog: onLog)
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func start() {
            report("正在蓝牙点火（连接仪表并应答心跳）…")
            ble.start { [weak self] in
                guard let self else { return }
                self.report("点火通道就绪，等待仪表接入 17818/15456…")
            }
            openListeners()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                sendLoop()
            }
        }

        private func openListeners() {
            guard active else { return }
            controlListener = makeListener(port: Self.controlPort, name: "控制 17818") { [weak self] connection in
                self?.acceptControl(connection)
            }
            videoListener = makeListener(port: Self.videoPort, name: "视频 15456") { [weak self] connection in
                self?.acceptVideo(connection)
            }
        }

        private func makeListener(port: UInt16, name: String,
                                  accept: @escaping (NWConnection) -> Void) -> NWListener? {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else {
                onLog("[凯越] \(name) 端口监听失败")
                return nil
            }
            listener.newConnectionHandler = accept
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onLog("[凯越] \(name) 已监听，等待仪表接入…")
                case .failed(let error): self?.onLog("[凯越] \(name) 监听失败：\(error.localizedDescription)")
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "CarWithin.kove.\(port)", qos: .userInitiated))
            return listener
        }

        // MARK: 控制通道

        private func acceptControl(_ connection: NWConnection) {
            guard active else { connection.cancel(); return }
            controlConnection?.cancel()
            controlConnection = connection
            controlBuffer = Data()
            onLog("[凯越] 仪表已接入控制通道（17818）")
            report("仪表已连入，等待视频通道…")
            startHeartbeat()
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.onLog("[凯越] 控制通道断开：\(error.localizedDescription)") }
                if case .cancelled = state { self?.stopHeartbeat() }
            }
            receiveControl(connection)
        }

        private func receiveControl(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, self.active else { return }
                if let data, !data.isEmpty {
                    self.controlBuffer.append(data)
                    self.drainControl()
                }
                if isComplete || error != nil {
                    self.onLog("[凯越] 控制通道已断开")
                    return
                }
                self.receiveControl(connection)
            }
        }

        /// 17818 帧格式（z10.f() + q83）：6 字节头 [type][sub][len 4B 大端]；
        /// type 0xEE/0xFD 为 JSON（len 含尾部 0xFF），type 1/2 常规，type 6 上行。
        private func drainControl() {
            while controlBuffer.count >= 6 {
                let bytes = [UInt8](controlBuffer.prefix(6))
                let length = Int(bytes[2]) << 24 | Int(bytes[3]) << 16 | Int(bytes[4]) << 8 | Int(bytes[5])
                guard controlBuffer.count >= 6 + length else { return }
                let payload = controlBuffer.subdata(in: 6..<(6 + length))
                controlBuffer.removeFirst(6 + length)
                let type = bytes[0], sub = bytes[1]
                if type == 0xEE, sub == 0xFD {
                    let body = payload.prefix(max(0, payload.count - 1))
                    if let json = String(data: body, encoding: .utf8) {
                        onLog("[凯越] 仪表 JSON：\(json.prefix(200))")
                        respondIfNeeded(json)
                    }
                } else {
                    onLog("[凯越] 仪表控制帧 type=\(type) sub=\(sub) len=\(length)")
                }
            }
        }

        private func respondIfNeeded(_ json: String) {
            // 激活状态查询等暂不实现；仪表多数查询可忽略。
        }

        private func startHeartbeat() {
            stopHeartbeat()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 10)
            timer.setEventHandler { [weak self] in
                guard let self, self.active, let connection = self.controlConnection else { return }
                // p30.q() 的 10 秒定时：请求版本号与周期心跳交替（t10.i / t10.l）。
                let frame: Data = self.heartbeatToggle ? Data([0x01, 0x11, 0, 0, 0, 0]) : Data([0x01, 0x01, 0, 0, 0, 0])
                self.heartbeatToggle.toggle()
                connection.send(content: frame, completion: .contentProcessed { _ in })
            }
            timer.resume()
            heartbeatTimer = timer
        }

        private func stopHeartbeat() {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }

        // MARK: 视频通道

        private func acceptVideo(_ connection: NWConnection) {
            guard active else { connection.cancel(); return }
            videoConnection?.cancel()
            videoConnection = connection
            onLog("[凯越] 仪表已接入视频通道（15456），发送会话头…")
            var head = [UInt8](repeating: 0, count: 69)
            let name = Array("android".utf8)
            for (index, byte) in name.enumerated() where index < 64 { head[1 + index] = byte }
            head[65] = UInt8((encodeWidth >> 8) & 0xFF)
            head[66] = UInt8(encodeWidth & 0xFF)
            head[67] = UInt8((encodeHeight >> 8) & 0xFF)
            head[68] = UInt8(encodeHeight & 0xFF)
            connection.send(content: Data(head), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.onLog("[凯越] 会话头发送失败：\(error.localizedDescription)")
                } else {
                    self.videoReady = true
                    self.report("仪表已就绪，等待 CarPlay 画面…")
                }
            })
        }

        // MARK: CarPlay 画面 → 重新编码 → 15456

        private func sendLoop() {
            var nextFrame = ProcessInfo.processInfo.systemUptime
            while active {
                if !videoReady { Thread.sleep(forTimeInterval: 0.1); continue }
                let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(profile.fps)
                let frame = queue.sync { () -> H264EncodedFrame? in
                    guard active, let image = latest else { return nil }
                    return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: false)
                }
                guard let frame else { continue }
                guard let connection = videoConnection, videoReady else { continue }
                connection.send(content: frame.data, completion: .contentProcessed { _ in })
                report("正在投屏 · \(profile.title) · H.264")
            }
        }

        func cancel() { lock.withLock { cancelled = true } }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                              fps: profile.fps, bitrate: profile.bitrate) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配凯越缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("[凯越]\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            videoReady = false
            stopHeartbeat()
            controlListener?.cancel(); controlListener = nil
            videoListener?.cancel(); videoListener = nil
            controlConnection?.cancel(); controlConnection = nil
            videoConnection?.cancel(); videoConnection = nil
            ble.stop()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }
}
