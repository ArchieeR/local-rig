import SwiftUI

enum LogSelection: String, CaseIterable, Identifiable {
    case dev = "Dev log"
    case emulator = "Emulator log"
    case command = "Commands"

    var id: Self { self }
}

struct LogPanelView: View {
    @Binding var selection: LogSelection
    @Binding var isExpanded: Bool
    let rig: RigSnapshot
    let commandOutput: String?
    let onHandoff: () -> Void
    let onReveal: (String) -> Void

    private var content: String {
        switch selection {
        case .dev: rig.devLogTail
        case .emulator: rig.emulatorLogTail
        case .command: commandOutput ?? "No dashboard commands have run for this rig."
        }
    }

    private var path: String? {
        switch selection {
        case .dev: rig.devLogPath
        case .emulator: rig.emulatorLogPath
        case .command: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text("Terminal")
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse terminal" : "Expand terminal")

                if isExpanded {
                    Picker("Log", selection: $selection) {
                        ForEach(LogSelection.allCases) { log in
                            Text(log.rawValue).tag(log)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                } else {
                    Text(selection.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                if isExpanded {
                    if let path {
                        Button("Reveal") { onReveal(path) }
                    }
                    Button("Copy") { PasteboardService.copy(content) }
                    Button("Send to agent") { onHandoff() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)

            if isExpanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(content.isEmpty ? "No log output." : content)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .transition(.opacity)
            }
        }
    }
}
