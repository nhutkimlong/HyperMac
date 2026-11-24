import Foundation
import ApplicationServices

/// Tự khôi phục quyền Accessibility sau khi app được cập nhật.
///
/// Vì sao cần: bản phát hành ký ad-hoc có Designated Requirement chỉ là `cdhash`,
/// nên mỗi lần update macOS coi là app khác và vô hiệu hoá quyền đã cấp. Entry cũ
/// vẫn nằm trong System Settings (trông như đang bật) nhưng không có tác dụng;
/// người dùng thường phải xoá app khỏi danh sách rồi thêm lại mới được.
///
/// Cách xử lý: khi chưa có quyền, reset entry TCC cũ (nếu có) **một lần cho mỗi
/// phiên bản** rồi gọi prompt hệ thống. Người dùng chỉ cần bật switch, không phải
/// xoá/thêm thủ công.
@MainActor
enum AccessibilityRecovery {
    private static let lastResetVersionKey = "ax_recovery_version"

    static func handleLaunch() {
        if AXIsProcessTrusted() { return }

        let defaults = UserDefaults.standard
        let signature = buildSignature()
        guard defaults.string(forKey: lastResetVersionKey) != signature else { return }

        defaults.set(signature, forKey: lastResetVersionKey)

        // Chạy tccutil trên background queue để không bao giờ block main thread khi khởi động.
        let bundleID = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            if let bundleID = bundleID, !bundleID.isEmpty {
                resetAccessibilityPermission(bundleID: bundleID)
            }
            // Đợi TCC xoá xong rồi mới hỏi lại, tránh prompt bị nuốt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard !AXIsProcessTrusted() else { return }
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    private static func buildSignature() -> String {
        let version = UpdateManager.currentVersion
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let mdate = attrs[.modificationDate] as? Date {
            return "\(version)_\(Int(mdate.timeIntervalSince1970))"
        }
        return version
    }

    nonisolated private static func resetAccessibilityPermission(bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            appLog("🔐 AccessibilityRecovery: reset quyền Accessibility cho \(bundleID) (mã \(process.terminationStatus))")
        } catch {
            appLog("⚠️ AccessibilityRecovery: không reset được quyền: \(error.localizedDescription)")
        }
    }
}
