import LibraryKit
import ShelfCore
import SwiftUI

extension View {
    /// The Files picker for EPUB, PDF and CBZ, importing whatever the person picks.
    func localFileImporter(isPresented: Binding<Bool>, model: AppModel) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: LocalFileTypes.all, allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await model.importFiles(urls) }
            case let .failure(error): model.report(error)
            }
        }
    }
}

/// "Importing Hollow Tide.cbz…" while files are being read.
@MainActor
struct FileImportBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let first = model.importingFiles.first {
            HStack(spacing: 10) {
                ProgressView()
                Text(model.importingFiles.count > 1 ? "Importing \(model.importingFiles.count) files…" : "Importing \(first)…")
                    .font(.subheadline).lineLimit(1)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("library.importing")
        }
    }
}

/// Asks before deleting an imported file, since the app keeps no other copy.
struct DeleteLocalFileDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var record: WorkRecord?
    var onDelete: () -> Void = {}

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete \(record?.title ?? "this file") from this device?",
            isPresented: Binding(get: { record != nil }, set: { if !$0 { record = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let key = record?.key { model.deleteLocal(key) }
                record = nil
                onDelete()
            }
        } message: {
            Text("Your reading place and highlights go too. The original file in Files isn't touched.")
        }
    }
}
