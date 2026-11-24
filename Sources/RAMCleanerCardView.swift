// SPDX-License-Identifier: GPL-3.0-only
// HyperMac — 1-Click RAM Cleaner Card View
// Modern, responsive card for Memory Cleaner

import SwiftUI
import AppKit

public struct RAMCleanerCardView: View {
    @ObservedObject var memoryManager: MemoryCleanerManager = MemoryCleanerManager.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            // Header: Icon + Title + Percent + Status
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)

                    Image(systemName: "memorychip")
                        .font(.system(size: FS.subhead, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tr("Bộ nhớ RAM", "Memory (RAM)"))
                            .font(.system(size: FS.subhead, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("\(Int(memoryManager.ramInfo.usedPercent.rounded()))%")
                            .font(.system(size: FS.subhead, weight: .bold, design: .rounded))
                            .foregroundStyle(memoryColor(percent: memoryManager.ramInfo.usedPercent))
                    }

                    HStack(spacing: 4) {
                        Text(tr("Đang dùng:", "Used:") + " \(MemoryCleanerManager.formatBytes(Int64(memoryManager.ramInfo.usedBytes)))")
                            .font(.system(size: FS.caption))
                            .foregroundStyle(.secondary)

                        Text("·")
                            .font(.system(size: FS.caption))
                            .foregroundStyle(.tertiary)

                        Text(tr("Trống:", "Free:") + " \(MemoryCleanerManager.formatBytes(Int64(memoryManager.ramInfo.freeBytes)))")
                            .font(.system(size: FS.caption))
                            .foregroundStyle(Tone.good)
                    }
                }

                Spacer()

                // 1-Click Clean Button
                Button {
                    memoryManager.cleanRAM()
                } label: {
                    HStack(spacing: 5) {
                        if memoryManager.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: FS.caption, weight: .bold))
                        }

                        Text(memoryManager.isCleaning ? tr("Đang dọn...", "Cleaning...") : tr("Dọn RAM", "Purge RAM"))
                            .font(.system(size: FS.caption, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(Rad.sm)
                }
                .buttonStyle(.plain)
                .disabled(memoryManager.isCleaning)
            }

            // Visual Segmented RAM Bar
            GeometryReader { geo in
                let total = max(1.0, Double(memoryManager.ramInfo.totalBytes))
                let usedW = max(0.0, (Double(memoryManager.ramInfo.usedBytes) / total) * Double(geo.size.width))
                let cacheW = max(0.0, (Double(memoryManager.ramInfo.cacheBytes) / total) * Double(geo.size.width))
                let freeW = max(0.0, Double(geo.size.width) - usedW - cacheW)

                HStack(spacing: 2) {
                    // App & Wired used
                    RoundedRectangle(cornerRadius: 3)
                        .fill(memoryColor(percent: memoryManager.ramInfo.usedPercent))
                        .frame(width: max(2, usedW))

                    // Inactive / Cache
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: max(2, cacheW))

                    // Free RAM
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.8))
                        .frame(width: max(2, freeW))
                }
            }
            .frame(height: 7)
            .padding(.vertical, 2)

            // Legend detail row
            HStack(spacing: 12) {
                legendItem(
                    color: memoryColor(percent: memoryManager.ramInfo.usedPercent),
                    label: tr("Đã dùng", "Used"),
                    val: MemoryCleanerManager.formatBytes(Int64(memoryManager.ramInfo.usedBytes))
                )

                legendItem(
                    color: Color.orange.opacity(0.85),
                    label: tr("Bộ đệm", "Cache"),
                    val: MemoryCleanerManager.formatBytes(Int64(memoryManager.ramInfo.cacheBytes))
                )

                legendItem(
                    color: Color.green.opacity(0.8),
                    label: tr("Trống", "Free"),
                    val: MemoryCleanerManager.formatBytes(Int64(memoryManager.ramInfo.freeBytes))
                )

                Spacer()
            }

            // Status feedback message banner
            if let msg = memoryManager.statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: FS.caption, weight: .bold))
                        .foregroundStyle(Tone.good)
                    Text(msg)
                        .font(.system(size: FS.caption, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Tone.good.opacity(0.12))
                .cornerRadius(Rad.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Rad.md).fill(Color(nsColor: .controlBackgroundColor)))
        .onAppear {
            memoryManager.startMonitoring()
        }
        .onDisappear {
            memoryManager.stopMonitoring()
        }
    }

    private func legendItem(color: Color, label: String, val: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label + ":")
                .font(.system(size: FS.caption - 1))
                .foregroundStyle(.secondary)
            Text(val)
                .font(.system(size: FS.caption - 1, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private func memoryColor(percent: Double) -> Color {
        if percent >= 85 {
            return Tone.bad
        } else if percent >= 70 {
            return Tone.warn
        } else {
            return Color.accentColor
        }
    }
}
