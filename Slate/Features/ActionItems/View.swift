//
//  ActionItems/View.swift
//  Slate
//
//  Hourly Outlook + Teams scrape → live to-do list with deadlines and
//  "who to respond to."
//

import SwiftUI

struct ActionItemsView: View {
    @StateObject private var vm = ActionItemsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .navigationTitle("Action Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Action Items").font(.title2.weight(.semibold))
                    Text("Live to-do list \u{00B7} hourly Outlook + Teams scrape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let last = vm.lastRefreshed {
                    Label(last.formatted(.relative(presentation: .named)),
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = vm.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var list: some View {
        if vm.items.isEmpty {
            ContentUnavailableView(
                "Inbox is quiet",
                systemImage: "checklist",
                description: Text("Nothing actionable yet. Slate checks every hour.")
            )
        } else {
            List {
                ForEach(ActionItemPriority.allCases, id: \.self) { priority in
                    let bucket = vm.items.filter { $0.priority == priority }
                    if !bucket.isEmpty {
                        Section(priority.label) {
                            ForEach(bucket) { item in
                                ActionItemRow(item: item) {
                                    vm.markDone(item.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onDone) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let person = item.respondTo {
                        Label(person, systemImage: "person.fill")
                    }
                    if let due = item.dueAt {
                        Label(due.formatted(.relative(presentation: .named)),
                              systemImage: "calendar")
                    }
                    Label(item.source.label, systemImage: item.source.systemImage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ActionItemsView().frame(width: 1000, height: 640)
}
