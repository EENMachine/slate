//
//  Views/View.swift
//  Slate
//
//  Content view tracker. Weekly insight drop every Wed 10:30 AM PT.
//

import SwiftUI

struct ViewsView: View {
    @StateObject private var vm = ViewsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Views")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.runWeeklyReportNow() }
                } label: {
                    Label("Run Report Now", systemImage: "play.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // TODO(slate-views): wire PDF export once platform list is locked.
                } label: {
                    Label("Export PDF", systemImage: "arrow.down.doc")
                }
                .disabled(vm.latestReport == nil)
                .help("PDF export — parked until Ian confirms the platform list.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Views").font(.title2.weight(.semibold))
                    Text("Weekly insight drop \u{00B7} Wed 10:30 AM PT")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let next = vm.nextScheduled {
                    Label(next.formatted(.relative(presentation: .named)),
                          systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = vm.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let report = vm.latestReport {
            ScrollView {
                WeeklyReportView(report: report)
                    .padding(20)
            }
        } else {
            ContentUnavailableView {
                Label("No report yet", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("Click Run Report Now, or wait for the Wednesday 10:30 AM PT tick.")
            }
        }
    }
}

/// Renders a `WeeklyViewReport` as a SwiftUI document. Same shape as a
/// real PDF would have — just without the PDFKit step.
struct WeeklyReportView: View {
    let report: WeeklyViewReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Branding.viewReportHeader)
                    .font(.caption.weight(.semibold).smallCaps())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text("Weekly View Report")
                    .font(.title.weight(.semibold))
                Text(report.generatedAt.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            headlineCard

            Divider()

            sectionHeader("Per-platform")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.perPlatform, id: \.platform) { row in
                    HStack {
                        Text(row.platform)
                        Spacer()
                        Text(Self.compact(row.totalViews))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            sectionHeader("Tracked content")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.snapshots) { snapshot in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.title).font(.body.weight(.medium))
                            Text(snapshot.platform)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Self.compact(snapshot.viewCount))
                                .font(.body.monospacedDigit())
                            Text("\(Self.compact(snapshot.likeCount)) likes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider().padding(.vertical, 6)

            HStack {
                Spacer()
                EENMACHINESWordmark(style: .artifact)
                Spacer()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }

    private var headlineCard: some View {
        HStack(spacing: 24) {
            statCell(label: "Total views", value: Self.compact(report.totalViews))
            if let top = report.topPerformer {
                statCell(label: "Top performer", value: top.title, sub: Self.compact(top.viewCount) + " views")
            }
            statCell(label: "Sources", value: "\(report.perPlatform.count)")
            Spacer()
        }
    }

    private func statCell(label: String, value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1)
            if let sub {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }
}

#Preview {
    ViewsView().frame(width: 1100, height: 700)
}
