import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 접속 목록 내보내기 (시트): 그룹을 골라 JSON 파일로 저장
struct HostExportView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    /// "" = 그룹 없음
    @State private var selectedGroups: Set<String> = []
    @State private var errorMessage: String?
    @State private var initialized = false

    private var groups: [String] {
        hostStore.groups + (hostStore.hosts.contains { ($0.group ?? "").isEmpty } ? [""] : [])
    }

    private func count(_ group: String) -> Int {
        hostStore.hosts.filter { ($0.group ?? "") == group }.count
    }

    private var selectedHosts: [SSHHost] {
        hostStore.hosts.filter { selectedGroups.contains($0.group ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("접속 목록 내보내기").font(.headline)
                Text("고른 그룹의 호스트를 JSON 파일로 저장합니다. 다른 Mac 이나 팀원의 MyTerminal 에서 가져올 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if hostStore.hosts.isEmpty {
                Text("내보낼 호스트가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { group in
                        Toggle(isOn: Binding(
                            get: { selectedGroups.contains(group) },
                            set: { on in
                                if on { selectedGroups.insert(group) } else { selectedGroups.remove(group) }
                            }
                        )) {
                            HStack {
                                Text(group.isEmpty ? "그룹 없음" : group)
                                Spacer()
                                Text("\(count(group))개").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("비밀번호는 내보내지 않습니다. 가져온 쪽에서 처음 접속할 때 입력하면 됩니다.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("취소") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("\(selectedHosts.count)개 내보내기…", action: export)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedHosts.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .onAppear {
            guard !initialized else { return }
            selectedGroups = Set(groups)
            initialized = true
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "접속 목록 내보내기"
        panel.nameFieldStringValue = HostTransfer.defaultFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HostTransfer.export(selectedHosts).write(to: url, options: .atomic)
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}

/// 접속 목록 가져오기 (시트): 파일 내용을 미리 보고 중복 처리 방식을 골라 가져온다
struct HostImportView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    let fileName: String
    let incoming: [SSHHost]

    @State private var policy: HostTransfer.DuplicatePolicy = .skip
    @State private var errorMessage: String?

    private var items: [HostTransfer.Item] { HostTransfer.plan(incoming: incoming, existing: hostStore.hosts) }
    private var duplicateCount: Int { items.filter { $0.existing != nil }.count }
    private var result: (insert: [SSHHost], update: [SSHHost]) { HostTransfer.resolve(items, policy: policy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("접속 목록 가져오기").font(.headline)
                Text("\(fileName) · 호스트 \(incoming.count)개 (새 호스트 \(incoming.count - duplicateCount)개, 이미 있음 \(duplicateCount)개)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            List(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.incoming.authMethod == .password ? "lock.fill" : "server.rack")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.incoming.displayName)
                        Text(detail(item.incoming))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    status(item)
                }
                .padding(.vertical, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if duplicateCount > 0 {
                    Picker("이미 있는 호스트", selection: $policy) {
                        ForEach(HostTransfer.DuplicatePolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if incoming.contains(where: { $0.authMethod == .password }) {
                    Label("비밀번호 방식 호스트는 처음 접속할 때 비밀번호를 입력하세요. (덮어쓰기는 기존에 저장된 비밀번호를 유지합니다)", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("취소") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(buttonTitle, action: importHosts)
                        .keyboardShortcut(.defaultAction)
                        .disabled(result.insert.isEmpty && result.update.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }

    private var buttonTitle: String {
        let r = result
        if r.update.isEmpty { return "\(r.insert.count)개 가져오기" }
        return "추가 \(r.insert.count)개 · 덮어쓰기 \(r.update.count)개"
    }

    @ViewBuilder
    private func status(_ item: HostTransfer.Item) -> some View {
        if item.existing == nil {
            Text("새 호스트").font(.caption).foregroundStyle(Color.accentColor)
        } else {
            Text(policy == .skip ? "이미 있음 · 건너뜀" : policy == .overwrite ? "이미 있음 · 덮어씀" : "이미 있음 · 복사본")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ host: SSHHost) -> String {
        var parts = [[host.user, host.hostname].compactMap { $0 }.joined(separator: "@")]
        if let port = host.port { parts.append("포트 \(port)") }
        if let group = host.group { parts.append(group) }
        return parts.joined(separator: " · ")
    }

    private func importHosts() {
        let r = result
        do {
            try hostStore.apply(insert: r.insert, update: r.update)
            dismiss()
        } catch {
            errorMessage = "가져오지 못했습니다: \(error.localizedDescription)"
        }
    }
}

/// 파일 선택 창을 띄워 접속 목록 파일을 읽는다. 취소하면 nil, 읽기 실패는 오류.
enum HostImportPicker {
    struct Loaded: Identifiable {
        let id = UUID()
        let fileName: String
        let hosts: [SSHHost]
    }

    static func pick() throws -> Loaded? {
        let panel = NSOpenPanel()
        panel.title = "접속 목록 가져오기"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let hosts = try HostTransfer.decode(Data(contentsOf: url))
        return Loaded(fileName: url.lastPathComponent, hosts: hosts)
    }
}
