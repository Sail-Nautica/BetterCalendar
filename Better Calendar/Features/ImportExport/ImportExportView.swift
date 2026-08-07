import SwiftUI

struct ImportExportView: View {
    let store: BetterCalendarStore

    @State private var importText = ""
    @State private var exportText = ""
    @State private var summaryText: String?

    var body: some View {
        Form {
            Section("Export ICS") {
                Button("Generate ICS", systemImage: "square.and.arrow.up") {
                    exportText = store.exportICS()
                }

                if !exportText.isEmpty {
                    Text(exportText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }

            Section("Import ICS") {
                TextField("Paste ICS text", text: $importText, axis: .vertical)
                    .lineLimit(6...12)
                    .font(.caption.monospaced())

                Button("Import Events", systemImage: "square.and.arrow.down") {
                    let summary = store.importICS(importText)
                    summaryText = "Imported \(summary.importedCount), skipped \(summary.skippedCount), failed \(summary.failedCount)."
                    if summary.importedCount > 0 {
                        importText = ""
                    }
                }
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let summaryText {
                    Text(summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Current Local State") {
                LabeledContent("Calendars", value: "\(store.calendars.count)")
                LabeledContent("Events", value: "\(store.events.count)")
                LabeledContent("Pending Mutations", value: "\(store.pendingMutations.count)")
                LabeledContent("Deleted Tombstones", value: "\(store.deletedEventTombstones.count)")
            }
        }
        .navigationTitle("Import / Export")
    }
}
