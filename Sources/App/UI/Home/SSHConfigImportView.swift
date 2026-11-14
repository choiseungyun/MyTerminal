import SwiftUI

/// ~/.ssh/config 에서 호스트 가져오기 (시트)
struct SSHConfigImportView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SSHConfigEntry] = []
    @State private var selected: Set<String> = []
    @State private var group = "SSH Config"
    @State private var errorMessage: String?
    @State private var loaded = false

    private var importedAliases: Set<String> { hostStore.importedAliases }
    private var importable: [SSHConfigEntry] { entries.filter { !importedAliases.contains($0.alias) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("~/.ssh/config 에서 가져오기")
                    .font(.headline)
                Text("가져온 호스트는 접속할 때 ssh 설정을 그대로 따릅니다 (`ssh 별칭`). 와일드카드(*) 항목과 Match 블록은 제외됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(FileManager.default.fileExists(atPath: SSHConfigParser.defaultConfigURL.path)
                         ? "가져올 Host 항목이 없습니다."
                         : "~/.ssh/config 파일이 없습니다.")
                    Text("ssh 설정 파일에 Host 항목을 추가하면 여기서 가져올 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        let already = importedAliases.contains(entry.alias)
                        Toggle(isOn: Binding(
                            get: { already || selected.contains(entry.alias) },
                            set: { on in
                                if on { selected.insert(entry.alias) } else { selected.remove(entry.alias) }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.alias)
                                    Text(detail(entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if already {
                                    Text("이미 추가됨")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(already)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("그룹")
                TextField("그룹", text: $group)
                    .frame(width: 160)
                if !importable.isEmpty {
                    Button(selected.count == importable.count ? "모두 해제" : "모두 선택") {
                        selected = selected.count == importable.count ? [] : Set(importable.map(\.alias))
                    }
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(selected.count)개 가져오기", action: importSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .task {
            entries = SSHConfigParser.parseFile()
            selected = Set(importable.map(\.alias))
            loaded = true
        }
    }

    private func detail(_ entry: SSHConfigEntry) -> String {
        var parts: [String] = []
        let address = [entry.user, entry.hostname ?? entry.alias].compactMap { $0 }.joined(separator: "@")
        parts.append(address)
        if let port = entry.port { parts.append("포트 \(port)") }
        if let jump = entry.proxyJump { parts.append("경유 \(jump)") }
        return parts.joined(separator: " · ")
    }

    private func importSelected() {
        let groupName = group.trimmingCharacters(in: .whitespaces)
        let hosts = entries
            .filter { selected.contains($0.alias) && !importedAliases.contains($0.alias) }
            .map { $0.makeHost(group: groupName.isEmpty ? nil : groupName) }
        do {
            try hostStore.insert(hosts)
            dismiss()
        } catch {
            errorMessage = "가져오지 못했습니다: \(error.localizedDescription)"
        }
    }
}
