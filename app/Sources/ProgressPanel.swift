import AppKit
import SwiftUI

// MARK: - 任务行与列表模型

@MainActor
final class JobRow: ObservableObject, Identifiable {
    enum Status {
        case running, done, failed, cancelled

        var iconName: String {
            switch self {
            case .running: return ""
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .cancelled: return "minus.circle.fill"
            }
        }
    }

    let id = UUID()
    let title: String
    @Published var status: Status = .running
    @Published var detail = ""
    let cancelToken = CancelToken()

    init(title: String) { self.title = title }
}

@MainActor
final class JobListModel: ObservableObject {
    @Published var jobs: [JobRow] = []

    func add(title: String) -> JobRow {
        let row = JobRow(title: title)
        jobs.append(row)
        if jobs.count > 30 { jobs.removeFirst(jobs.count - 30) }
        return row
    }
}

// MARK: - 进度窗 SwiftUI

private struct JobRowView: View {
    @ObservedObject var row: JobRow

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if row.status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: row.status.iconName)
                        .foregroundStyle(row.status == .done ? Color.green
                                         : row.status == .failed ? Color.red
                                         : Color.secondary)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if row.status == .running {
                Button("取消") { row.cancelToken.cancel() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProgressListView: View {
    @ObservedObject var model: JobListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("金桔任务")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(model.jobs.suffix(6))) { row in
                JobRowView(row: row)
            }
            if model.jobs.isEmpty {
                Text("暂无任务")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - 进度窗面板控制器

/// 右下角任务面板:任务开始自动出现,全部结束 2.5s 后自动收起。
@MainActor
final class ProgressPanelController {
    private let model: JobListModel
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    init(model: JobListModel) { self.model = model }

    func show() {
        hideTask?.cancel()
        guard panel == nil else { return }
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220))
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ProgressListView(model: model))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 340 - 12, y: visible.minY + 90))
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hideAfter(seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
