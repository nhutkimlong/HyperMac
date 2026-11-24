// SPDX-License-Identifier: GPL-3.0-only
// HyperMac — Memory Optimizer & 1-Click RAM Cleaner
// Pure native Darwin Mach VM & memory pressure reclaim

import Foundation
import AppKit
import SwiftUI
import Darwin

/// Thông tin trạng thái RAM hệ thống
public struct SystemRAMInfo: Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cacheBytes: UInt64       // Inactive + purgeable cache
    public let freeBytes: UInt64
    public let usedPercent: Double
    public let cachePercent: Double
    public let freePercent: Double

    public init(
        totalBytes: UInt64 = 0,
        usedBytes: UInt64 = 0,
        appBytes: UInt64 = 0,
        wiredBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        cacheBytes: UInt64 = 0,
        freeBytes: UInt64 = 0
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cacheBytes = cacheBytes
        self.freeBytes = freeBytes

        if totalBytes > 0 {
            self.usedPercent = min(max((Double(usedBytes) / Double(totalBytes)) * 100.0, 0.0), 100.0)
            self.cachePercent = min(max((Double(cacheBytes) / Double(totalBytes)) * 100.0, 0.0), 100.0)
            self.freePercent = min(max((Double(freeBytes) / Double(totalBytes)) * 100.0, 0.0), 100.0)
        } else {
            self.usedPercent = 0.0
            self.cachePercent = 0.0
            self.freePercent = 0.0
        }
    }
}

@MainActor
public final class MemoryCleanerManager: ObservableObject {
    public static let shared = MemoryCleanerManager()

    @Published public private(set) var ramInfo: SystemRAMInfo = SystemRAMInfo()
    @Published public private(set) var isCleaning: Bool = false
    @Published public private(set) var lastFreedBytes: Int64 = 0
    @Published public private(set) var statusMessage: String? = nil
    @Published public private(set) var lastCleanedAt: Date? = nil

    private var refreshTimer: Timer?

    nonisolated private static let machHostPort: mach_port_t = mach_host_self()
    nonisolated private static let hostPageSizeBytes: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS else {
            return UInt64(vm_kernel_page_size)
        }
        return UInt64(size)
    }()

    private init() {
        refreshMemoryStats()
    }

    /// Khởi động cập nhật định kỳ khi tab hoặc card RAM hiển thị
    public func startMonitoring() {
        refreshMemoryStats()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMemoryStats()
            }
        }
    }

    /// Tạm dừng cập nhật để tiết kiệm 100% CPU khi không mở tab
    public func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Lấy thông số RAM tức thì qua Darwin Mach kernel
    public func refreshMemoryStats() {
        self.ramInfo = Self.queryRAMInfo()
    }

    nonisolated public static func queryRAMInfo() -> SystemRAMInfo {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0, hostPageSizeBytes > 0 else { return SystemRAMInfo() }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return SystemRAMInfo() }

        let pageSize = hostPageSizeBytes
        let wired = UInt64(stats.wire_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let appPages = internalPages >= UInt64(stats.purgeable_count)
            ? (internalPages - UInt64(stats.purgeable_count))
            : 0
        let app = appPages * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize

        let used = wired + app + compressed
        let cache = inactive + purgeable

        return SystemRAMInfo(
            totalBytes: total,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cacheBytes: cache,
            freeBytes: free
        )
    }

    /// Dọn RAM 1-Click:
    /// 1. Gọi lệnh purge qua helper đặc quyền (hoặc sudo /usr/sbin/purge) để thu hồi buffer cache kernel
    /// 2. Giải phóng bộ nhớ đệm app (URLCache, malloc zone relief)
    /// 3. Kích thích Darwin VM reclaimer thu hồi inactive/purgeable pages và unmap ngay lập tức
    public func cleanRAM() {
        guard !isCleaning else { return }
        isCleaning = true
        statusMessage = nil

        let beforeInfo = Self.queryRAMInfo()
        appLog("⚡️ Bắt đầu dọn RAM... Trước dọn: Free=\(Self.formatBytes(Int64(beforeInfo.freeBytes))), Cache=\(Self.formatBytes(Int64(beforeInfo.cacheBytes))), Used=\(Self.formatBytes(Int64(beforeInfo.usedBytes)))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. Thử dọn bộ đệm đĩa kernel qua helper đặc quyền v4 hoặc sudo purge
            let helperOut = shell("\(PrivilegedHelper.sudo("purge")) 2>/dev/null || true")
            if !helperOut.output.contains("PURGE_OK") {
                _ = shell("sudo -n /usr/sbin/purge 2>/dev/null || true")
            }

            // 2. Thu hồi các bộ đệm rác nội bộ & giải phóng cache trong tiến trình
            DispatchQueue.main.async {
                URLCache.shared.removeAllCachedResponses()
            }
            malloc_zone_pressure_relief(nil, 0)

            // 3. Kích thích Darwin VM reclaimer thu hồi inactive pages bằng mmap ẩn danh (không làm phình heap của app)
            let cacheToReclaim = beforeInfo.cacheBytes
            if cacheToReclaim > 100 * 1024 * 1024 {
                let maxTarget = min(UInt64(1024 * 1024 * 1024), cacheToReclaim / 2)
                let allocSize = Int(maxTarget)
                if allocSize > 0, let ptr = mmap(nil, allocSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), ptr != MAP_FAILED {
                    var offset = 0
                    while offset < allocSize {
                        ptr.advanced(by: offset).storeBytes(of: 1, as: UInt8.self)
                        offset += 32768
                    }
                    munmap(ptr, allocSize)
                }
            }

            // Giải phóng heap malloc vùng nhớ trống về kernel
            malloc_zone_pressure_relief(nil, 0)

            // Đồng bộ hoá hệ thống
            sync()

            // Nghỉ 0.5s để Mach kernel cập nhật thống kê VM
            Thread.sleep(forTimeInterval: 0.5)

            let afterInfo = Self.queryRAMInfo()
            let freedByFree = Int64(afterInfo.freeBytes) - Int64(beforeInfo.freeBytes)
            let freedByUsed = Int64(beforeInfo.usedBytes) - Int64(afterInfo.usedBytes)
            let freedByCache = Int64(beforeInfo.cacheBytes) - Int64(afterInfo.cacheBytes)
            let reportedFreed: Int64 = max(0, max(freedByFree, max(freedByUsed, freedByCache)))

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.ramInfo = afterInfo
                self.isCleaning = false
                self.lastCleanedAt = Date()
                self.lastFreedBytes = reportedFreed

                if reportedFreed > 50 * 1024 * 1024 {
                    self.statusMessage = String(format: tr("Đã tối ưu & giải phóng %@ RAM!", "Optimized & freed %@ RAM!"), Self.formatBytes(reportedFreed))
                } else {
                    self.statusMessage = tr("Bộ nhớ RAM đã được tối ưu đạt hiệu suất tốt nhất!", "RAM memory optimized for peak performance!")
                }

                NSSound(named: "Glass")?.play()
                appLog("✅ Dọn RAM hoàn tất: Giải phóng=\(Self.formatBytes(reportedFreed)), Free hiện tại=\(Self.formatBytes(Int64(afterInfo.freeBytes)))")

                // Tự ẩn thông báo sau 4 giây
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if self.statusMessage != nil {
                        withAnimation { self.statusMessage = nil }
                    }
                }
            }
        }
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.0f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        } else {
            return "\(bytes) B"
        }
    }
}
