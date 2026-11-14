import AppKit
import SwiftUI

/// 히스토리: 접속 이력 표 (날짜·시간, 이 Mac 사용자, 호스트, 저장 여부)
struct HistoryView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var history: HistoryStore

    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var newestFirst = true
    @State private var confirmClear = false

    private var records: [ConnectionRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? history.records : history.records.filter { r in
            [r.title, r.user ?? "", r.arguments.joined(separator: " "), r.localUser, r.localMachine]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return newestFirst ? filtered : filtered.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)

            if history.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("아직 접속 이력이 없습니다")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("서버에 SSH·SFTP 로 접속하면 언제, 어디에, 얼마나 접속했는지 여기에 남습니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .background(Theme.contentBackground)
        .confirmationDialog("접속 이력을 모두 지울까요?", isPresented: $confirmClear) {
            Button("모두 지우기", role: .destructive) { history.clear() }
        } message: {
            Text("저장된 호스트는 지워지지 않습니다.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("접속 이력")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(history.records.count)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("", text: $query, prompt: Text("호스트·사용자 검색").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            Button {
                newestFirst.toggle()
            } label: {
                Label(newestFirst ? "최근 순" : "오래된 순", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            Button("모두 지우기…") { confirmClear = true }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .disabled(history.records.isEmpty)
        }
    }

    private var table: some View {
        Table(records, selection: $selection) {
            TableColumn("날짜") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryFormat.day(record.startedAt))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    Text(HistoryFormat.timeRange(record, isOpen: store.isOpen(record)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }
            .width(min: 150, ideal: 190)

            TableColumn("사용자") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.localUser)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    Text(record.localMachine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("호스트") { record in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.hostIcon)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: record.kind == .sftp ? "folder.fill" : "server.rack")
                                .font(.system(size: 12))
                                .foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentTitle(record))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(record.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .help(SSHCommand.commandLine(record.arguments))
            }
            .width(min: 180, ideal: 300)

            TableColumn("저장") { record in
                let saved = isSaved(record)
                Button {
                    if !saved { save(record) }
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(saved ? Theme.accent : Theme.textSecondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(saved ? "저장된 호스트" : "호스트로 저장")
            }
            .width(56)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            let items = records.filter { ids.contains($0.id) }
            if items.count == 1 {
                Button("다시 접속") { store.reconnect(items[0]) }
                if !isSaved(items[0]) {
                    Button("호스트로 저장") { save(items[0]) }
                }
                Button("ssh 명령 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SSHCommand.commandLine(items[0].arguments), forType: .string)
                }
                Divider()
            }
            if !items.isEmpty {
                Button("기록 삭제", role: .destructive) { history.delete(Set(items.map(\.id))) }
            }
        } primaryAction: { ids in
            // 더블클릭: 다시 접속
            if let record = records.first(where: { ids.contains($0.id) }) { store.reconnect(record) }
        }
    }

    // MARK: - 도움

    /// 저장된 호스트가 아직 있으면 지금 이름, 아니면 기록 당시 이름
    private func currentTitle(_ record: ConnectionRecord) -> String {
        record.hostID.flatMap(hostStore.host)?.displayName ?? record.title
    }

    private func isSaved(_ record: ConnectionRecord) -> Bool {
        record.hostID.flatMap(hostStore.host) != nil
    }

    /// 저장하지 않은 접속을 호스트로 저장하고, 같은 접속 기록을 그 호스트에 연결한다.
    private func save(_ record: ConnectionRecord) {
        guard let target = record.quickTarget else { return }
        var host = SSHHost(quickConnect: target)
        host.name = record.title == host.hostname ? "" : record.title
        do {
            try hostStore.save(host)
            history.link(arguments: record.arguments, to: host.id)
        } catch {
            NSLog("[MyTerminal] 호스트 저장 실패: \(error)")
        }
    }
}

/// 접속 이력 표시 형식
enum HistoryFormat {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "13:42 - 13:51", 날짜를 넘기면 "16:56 - 09:59 (+2일)", 접속 중이면 "13:42 - 접속 중"
    static func timeRange(_ record: ConnectionRecord, isOpen: Bool, calendar: Calendar = .current) -> String {
        let start = timeFormatter.string(from: record.startedAt)
        guard let end = record.endedAt else {
            return isOpen ? "\(start) - 접속 중" : "\(start) - 종료 기록 없음"
        }
        var text = "\(start) - \(timeFormatter.string(from: end))"
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: record.startedAt), to: calendar.startOfDay(for: end)).day ?? 0
        if days > 0 { text += " (+\(days)일)" }
        return text
    }
}
