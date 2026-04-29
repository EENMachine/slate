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
        }
    }

    private var header: some View {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if vm.tracked.isEmpty {
            ContentUnavailableView {
                Label("No tracked content yet", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("Drop video files or paste links to start tracking.")
            } actions: {
                Button("Add link…") { vm.promptForLink() }
            }
        } else {
            List {
                Section("Tracked") {
                    ForEach(vm.tracked) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body.weight(.medium))
                                Text(item.platform.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.viewCountFormatted)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ViewsView().frame(width: 1000, height: 640)
}
