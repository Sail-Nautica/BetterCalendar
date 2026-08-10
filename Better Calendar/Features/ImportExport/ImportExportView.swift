import SwiftUI
import UniformTypeIdentifiers

/// BC-ICS-001/003 (spec 1.18): parse → preview (imported/skipped/failed counts + destination
/// calendar) → confirm, from either a picked `.ics` file or pasted text. BC-ICS-002/003
/// (spec 1.19): export by scope, shared/saved via the system share sheet rather than a
/// select-and-copy text block.
struct ImportExportView: View {
    let store: BetterCalendarStore

    @State private var importText = ""
    @State private var pendingImportSummary: ImportSummary?
    @State private var destinationCalendarID: UUID?
    @State private var commitSummaryText: String?
    @State private var isShowingFileImporter = false
    @State private var importErrorMessage: String?

    @State private var exportScopeCalendarID: UUID?
    @State private var exportedICSDocument: ICSDocument?

    var body: some View {
        Form {
            Section("Export ICS") {
                Picker("Scope", selection: $exportScopeCalendarID) {
                    Text("All Calendars").tag(UUID?.none)
                    ForEach(store.calendars) { calendar in
                        Text(calendar.name).tag(Optional(calendar.id))
                    }
                }

                Button("Prepare Export", systemImage: "square.and.arrow.up") {
                    let scope: BetterCalendarStore.ICSExportScope = exportScopeCalendarID.map { .calendar($0) } ?? .all
                    exportedICSDocument = ICSDocument(text: store.exportICS(scope: scope))
                }

                if let exportedICSDocument {
                    ShareLink(item: exportedICSDocument, preview: SharePreview("Better Calendar Export.ics")) {
                        Label("Share / Save .ics File", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }

            Section("Import ICS") {
                Button("Choose .ics File…", systemImage: "doc.badge.plus") {
                    isShowingFileImporter = true
                }

                TextField("Or paste ICS text", text: $importText, axis: .vertical)
                    .lineLimit(4...8)
                    .font(.caption.monospaced())

                Button("Preview Import", systemImage: "eye") {
                    beginPreview(text: importText)
                }
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let importErrorMessage {
                    Text(importErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let pendingImportSummary {
                Section("Import Preview") {
                    LabeledContent("Will Import", value: "\(pendingImportSummary.events.count)")
                    LabeledContent("Skipped (Duplicates)", value: "\(pendingImportSummary.skippedCount)")
                    LabeledContent("Failed", value: "\(pendingImportSummary.failedCount)")

                    if !store.calendars.isEmpty {
                        Picker("Destination Calendar", selection: $destinationCalendarID) {
                            ForEach(store.calendars) { calendar in
                                Text(calendar.name).tag(Optional(calendar.id))
                            }
                        }
                    }

                    Button("Confirm Import", systemImage: "checkmark.circle") {
                        let summary = store.commitImport(pendingImportSummary, destinationCalendarID: destinationCalendarID)
                        commitSummaryText = "Imported \(summary.importedCount), skipped \(summary.skippedCount), failed \(summary.failedCount)."
                        self.pendingImportSummary = nil
                        importText = ""
                    }
                    .disabled(pendingImportSummary.events.isEmpty)

                    Button("Cancel", role: .cancel) {
                        self.pendingImportSummary = nil
                    }
                }
            }

            if let commitSummaryText {
                Section {
                    Text(commitSummaryText)
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
        .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: [.icsCalendar, .plainText, .data], onCompletion: handleFileImportResult)
        .onAppear {
            if destinationCalendarID == nil {
                destinationCalendarID = store.defaultCalendarID
            }
        }
    }

    private func beginPreview(text: String) {
        importErrorMessage = nil
        commitSummaryText = nil
        let summary = store.previewImportICS(text)
        guard !summary.events.isEmpty else {
            importErrorMessage = "No events could be parsed from this file."
            pendingImportSummary = nil
            return
        }
        pendingImportSummary = summary
    }

    private func handleFileImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                importErrorMessage = "Could not read that file."
                return
            }
            importText = text
            beginPreview(text: text)
        case .failure:
            importErrorMessage = "Could not open that file."
        }
    }
}

private struct ICSDocument: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .icsCalendar) { document in
            Data(document.text.utf8)
        }
        .suggestedFileName("Better Calendar Export.ics")
    }
}

extension UTType {
    static var icsCalendar: UTType {
        UTType(filenameExtension: "ics") ?? .plainText
    }
}
