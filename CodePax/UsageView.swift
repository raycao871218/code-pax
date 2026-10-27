import SwiftUI

struct UsageView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private var tokens: ThreadTokenUsage? { model.selected?.tokenUsage }

    var body: some View {
        NavigationStack {
            Form {
                if let usage = model.accountUsage, !usage.buckets.isEmpty {
                    ForEach(usage.buckets, id: \.id) { bucket in
                        Section(bucket.value.limitName ?? bucket.id) {
                            if let plan = bucket.value.planType { LabeledContent("套餐", value: plan) }
                            if let primary = bucket.value.primary { UsageWindowRow(window: primary) }
                            if let secondary = bucket.value.secondary { UsageWindowRow(window: secondary) }
                            if bucket.value.primary == nil && bucket.value.secondary == nil {
                                Text("服务器暂未提供额度窗口。 ").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let updatedAt = usage.updatedAt {
                        Section {
                            LabeledContent("额度更新时间") {
                                Text(Date(timeIntervalSince1970: updatedAt), format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("账号额度") {
                        Text(model.isUsageLoading ? "正在读取服务器账号额度…" : "当前暂无账号额度数据。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("当前会话") {
                    if let tokens {
                        LabeledContent("累计 token", value: tokens.total.totalTokens.formatted())
                        if let fraction = tokens.contextFraction, let window = tokens.modelContextWindow {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("上下文占用（估算）")
                                    Spacer()
                                    Text(fraction, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary)
                                }
                                ProgressView(value: fraction)
                                Text("最近一次请求 / 上下文上限 \(window.formatted()) token")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                        DisclosureGroup("Token 明细") {
                            LabeledContent("输入", value: tokens.total.inputTokens.formatted())
                            LabeledContent("其中缓存输入", value: tokens.total.cachedInputTokens.formatted())
                            LabeledContent("输出", value: tokens.total.outputTokens.formatted())
                            LabeledContent("其中推理输出", value: tokens.total.reasoningOutputTokens.formatted())
                            LabeledContent("最近一次请求", value: tokens.last.totalTokens.formatted())
                            Text("缓存已计入输入，推理已计入输出，不重复相加。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("尚未收到这条会话的 token 用量。运行下一次任务后自动更新。")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.usageError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                        if model.accountUsage != nil { Text("已显示的额度可能是上次成功读取的结果。 ").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Text("来自服务器当前登录的 Codex 账号。缺失值表示暂不可用，不代表额度为零。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Usage").navigationBarTitleDisplayMode(.inline)
                .refreshable { await model.refreshUsage(force: true) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Task { await model.refreshUsage(force: true) } } label: {
                            if model.isUsageLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }.disabled(model.isUsageLoading).accessibilityLabel("刷新用量")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }.appAppearance().task {
            await model.refreshUsage()
        }
    }
}

private struct UsageWindowRow: View {
    let window: RateLimitWindow
    private var usageColor: Color {
        switch window.severity {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.title)
                Spacer()
                Text("剩余 \(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                    .foregroundStyle(usageColor).monospacedDigit()
            }
            ProgressView(value: window.remainingPercent / 100)
                .tint(usageColor)
            if let reset = window.resetsAt {
                HStack(spacing: 4) {
                    Text("重置时间")
                    Text(Date(timeIntervalSince1970: reset), format: .dateTime.month().day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
