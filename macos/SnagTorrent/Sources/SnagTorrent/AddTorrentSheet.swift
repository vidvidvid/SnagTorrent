import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var startPaused = false
    let onAdd: (String, Bool) -> Void

    private var trimmed: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Torrent")
                .font(.title2.weight(.semibold))
            Text("Paste a magnet link, info hash, or torrent URL, or choose a .torrent file.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("magnet:?xt=urn:btih:…", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Choose File…", action: chooseFile)
            }
            Toggle("Start paused", isOn: $startPaused)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefillFromClipboard)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, startPaused)
        dismiss()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            source = url.path
        }
    }

    private func prefillFromClipboard() {
        guard source.isEmpty,
              let text = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        let isHash = text.count == 40 && text.allSatisfy(\.isHexDigit)
        if text.hasPrefix("magnet:") || isHash || text.hasSuffix(".torrent") {
            source = text
        }
    }
}
