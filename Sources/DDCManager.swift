import Foundation
import IOKit
import CoreAudio

// MARK: - Private IOAVService C-APIs for Apple Silicon DDC/CI

typealias IOAVServiceRef = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: IOAVServiceRef,
    _ chipAddress: UInt32,
    _ dataAddress: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: IOAVServiceRef,
    _ chipAddress: UInt32,
    _ dataAddress: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32
) -> IOReturn

// MARK: - CoreAudio Audio Device Helper

public class AudioDeviceHelper {
    /// Kiểm tra xem thiết bị xuất âm thanh mặc định hiện tại có phải là màn hình ngoài (HDMI/DisplayPort/Type-C)
    /// mà macOS không hỗ trợ chỉnh âm lượng gốc hay không.
    public static func isDefaultAudioOutputExternalDisplay() -> Bool {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != 0 else { return false }

        // Kiểm tra xem thiết bị này có thuộc tính chỉnh âm lượng phần cứng của macOS không
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasNativeVolume = AudioObjectHasProperty(defaultOutputDeviceID, &volAddress)
        return !hasNativeVolume
    }
}

// MARK: - DDC Manager

public final class DDCManager: @unchecked Sendable {
    public static let shared = DDCManager()

    private let queue = DispatchQueue(label: "com.hypermac.ddc", qos: .userInitiated)
    private var cachedServices: [IOAVServiceRef] = []
    private var lastServiceRefresh: Date = .distantPast

    // Coalescing debounce for rapid slider movement
    private var pendingVolume: Int? = nil
    private var isDispatchingVolume = false

    private var pendingBrightness: Int? = nil
    private var isDispatchingBrightness = false

    private init() {}

    // MARK: - Enumerate External IOAVServices

    private func getExternalAVServices() -> [IOAVServiceRef] {
        let now = Date()
        if !cachedServices.isEmpty && now.timeIntervalSince(lastServiceRefresh) < 15.0 {
            return cachedServices
        }

        var services: [IOAVServiceRef] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return services
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let locRef = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)
            if let loc = locRef?.takeRetainedValue() as? String, loc == "External" {
                if let unmanaged = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
                    services.append(unmanaged.takeRetainedValue())
                }
            }
        }

        self.cachedServices = services
        self.lastServiceRefresh = now
        return services
    }

    // MARK: - Send DDC VCP Command

    /// Gửi lệnh ghi giá trị VCP (Virtual Control Panel) qua giao thức DDC/CI I2C
    @discardableResult
    private func writeVCP(opcode: UInt8, value: UInt8) -> Bool {
        let avServices = getExternalAVServices()
        guard !avServices.isEmpty else {
            appLog("⚠️ DDCManager: No external DCPAVServiceProxy found.")
            return false
        }

        var success = false
        for service in avServices {
            // Chuẩn khung DDC/CI Set VCP Feature:
            // [Length/Flags, Set VCP Opcode (0x03), VCP Code, Value High Byte, Value Low Byte, Checksum]
            var packet: [UInt8] = [
                0x84,
                0x03,
                opcode,
                0x00,
                value,
                0x00
            ]
            let sourceAddress: UInt8 = 0x51
            let commandID: UInt8 = 0x6E
            var checksum = commandID ^ sourceAddress
            for b in packet[0..<5] {
                checksum ^= b
            }
            packet[5] = checksum

            let count = UInt32(packet.count)
            let status = packet.withUnsafeMutableBytes { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnBadArgument }
                return IOAVServiceWriteI2C(service, 0x37, 0x51, base, count)
            }

            if status == KERN_SUCCESS {
                success = true
            } else {
                appLog("⚠️ DDCManager: Write opcode 0x\(String(format: "%02X", opcode)) failed with code \(status)")
            }
        }
        return success
    }

    // MARK: - Public Volume Control APIs

    /// Chỉnh âm lượng loa màn hình ngoài (VCP 0x62) từ 0 đến 100
    public func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingVolume = clamped
            if !self.isDispatchingVolume {
                self.isDispatchingVolume = true
                self.dispatchPendingVolume()
            }
        }
    }

    private func dispatchPendingVolume() {
        guard let target = self.pendingVolume else {
            self.isDispatchingVolume = false
            return
        }
        self.pendingVolume = nil
        _ = self.writeVCP(opcode: 0x62, value: UInt8(target))

        // Small cooldown to prevent flooding I2C bus while slider moves
        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self else { return }
            if self.pendingVolume != nil {
                self.dispatchPendingVolume()
            } else {
                self.isDispatchingVolume = false
            }
        }
    }

    /// Tắt/Bật tiếng loa màn hình ngoài (VCP 0x8D: 1 = Mute, 2 = Unmute)
    public func setMute(_ muted: Bool) {
        queue.async { [weak self] in
            // VCP 0x8D: 1 = Mute, 2 = Unmute
            _ = self?.writeVCP(opcode: 0x8D, value: muted ? 0x01 : 0x02)
        }
    }

    // MARK: - Public Hardware Brightness Control APIs

    /// Đọc giá trị VCP từ màn hình ngoài (ví dụ VCP 0x10 cho độ sáng)
    public func readVCP(opcode: UInt8) -> (current: Int, max: Int)? {
        let avServices = getExternalAVServices()
        guard let service = avServices.first else { return nil }

        var req: [UInt8] = [0x82, 0x01, opcode, 0x00]
        var cs: UInt8 = 0x6E ^ 0x51
        for b in req[0..<3] { cs ^= b }
        req[3] = cs
        let rCount = UInt32(req.count)

        let writeStatus = req.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnBadArgument }
            return IOAVServiceWriteI2C(service, 0x37, 0x51, base, rCount)
        }
        guard writeStatus == KERN_SUCCESS else { return nil }

        usleep(45000) // Đợi màn hình chuẩn bị phản hồi (45ms)

        var reply = [UInt8](repeating: 0, count: 12)
        let replyCount = UInt32(reply.count)
        let readStatus = reply.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnBadArgument }
            return IOAVServiceReadI2C(service, 0x37, 0x51, base, replyCount)
        }
        guard readStatus == KERN_SUCCESS else { return nil }

        if reply[2] == 0x02 && reply[3] == 0x00 && reply[4] == opcode {
            let maxVal = (Int(reply[6]) << 8) | Int(reply[7])
            let curVal = (Int(reply[8]) << 8) | Int(reply[9])
            return (current: curVal, max: max(1, maxVal))
        }
        return nil
    }

    /// Đọc độ sáng thực tế của phần cứng màn hình ngoài (0...100)
    public func readBrightness() -> Int? {
        if let result = readVCP(opcode: 0x10) {
            return result.current
        }
        return nil
    }

    /// Điều chỉnh độ sáng phần cứng màn hình ngoài (VCP 0x10) từ 0 đến 100
    public func setBrightness(_ brightness: Int) {
        let clamped = max(0, min(100, brightness))
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingBrightness = clamped
            if !self.isDispatchingBrightness {
                self.isDispatchingBrightness = true
                self.dispatchPendingBrightness()
            }
        }
    }

    private func dispatchPendingBrightness() {
        guard let target = self.pendingBrightness else {
            self.isDispatchingBrightness = false
            return
        }
        self.pendingBrightness = nil
        _ = self.writeVCP(opcode: 0x10, value: UInt8(target))

        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self else { return }
            if self.pendingBrightness != nil {
                self.dispatchPendingBrightness()
            } else {
                self.isDispatchingBrightness = false
            }
        }
    }
}
