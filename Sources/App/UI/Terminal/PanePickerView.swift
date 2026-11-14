import SwiftUI

/// 대상 선택 칸에 보이는 항목 하나
struct PanePickerOption: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String?
    let choice: PaneChoice

    /// 검색어에 맞는 항목들. 검색어가 없으면 "같은 서버"가 맨 앞이라 Enter 만 누르면 된다.
    static func options(for picker: PanePicker, query: String, hosts: [SSHHost]) -> [PanePickerOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var result: [PanePickerOption] = []

        if q.isEmpty {
            if let origin = picker.originTarget {
                result.append(PanePickerOption(
                    id: "same", symbol: "arrow.triangle.branch", title: "같은 서버: \(origin.title)",
                    subtitle: origin.displayCommand, choice: .same))
                result.append(PanePickerOption(
                    id: "local", symbol: "terminal", title: "로컬 터미널", subtitle: "이 Mac", choice: .local))
            } else {
                result.append(PanePickerOption(
                    id: "same", symbol: "terminal", title: "로컬 터미널",
                    subtitle: picker.originDirectory.map { "이 Mac · \($0)" } ?? "이 Mac", choice: .same))
            }
        }

        let matched = hosts.filter { $0.matches(q) }
        let quick = QuickConnectTarget(q)
        // user@host 나 ssh 명령이면 바로 접속을 맨 앞에, 저장된 호스트가 없을 때도 접속을 제안한다
        let looksLikeTarget = q.contains("@") || q.hasPrefix("ssh ")
        let quickOption = quick.map {
            PanePickerOption(
                id: "quick", symbol: "bolt.horizontal", title: "접속: \($0.sshCommand)",
                subtitle: "빠른 연결", choice: .quick($0))
        }

        if looksLikeTarget, let quickOption { result.append(quickOption) }
        result += matched.prefix(50).map { host in
            PanePickerOption(
                id: host.id.uuidString, symbol: "server.rack", title: host.displayName,
                subtitle: [host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname, host.group]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                choice: .host(host))
        }
        if !looksLikeTarget, matched.isEmpty, let quickOption { result.append(quickOption) }
        return result
    }
}

/// 분할로 생긴 새 칸: 무엇을 열지 고른다.
/// 같은 서버(Enter) · 로컬 터미널 · 저장된 호스트(검색) · user@host 빠른 연결
struct PanePickerView: View {
    let picker: PanePicker
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var hostStore = HostStore.shared

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var isFocused: Bool { tab.focusedPaneID == picker.id }
    private var options: [PanePickerOption] {
        PanePickerOption.options(for: picker, query: query, hosts: hostStore.hosts)
    }

    var body: some View {
        let options = options
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("이 화면에 열기")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { store.closePane(picker.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("분할 취소 (Esc)")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("호스트 검색 또는 user@host", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { pick(options) }
                    .onKeyPress(.downArrow) { move(1, count: options.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: options.count); return .handled }
                    .onKeyPress(.escape) { store.closePane(picker.id); return .handled }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            row(option, selected: index == selection)
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    store.resolvePicker(picker.id, with: option.choice)
                                }
                        }
                    }
                }
                .onChange(of: selection) { _, index in proxy.scrollTo(index) }
            }

            if options.isEmpty {
                Text("일치하는 호스트가 없습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("↑↓ 선택 · Enter 열기 · Esc 취소")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: 440, maxHeight: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Theme.accent.opacity(0.6) : Theme.divider, lineWidth: 1))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .contentShape(Rectangle())
        .onTapGesture { tab.focusedPaneID = picker.id }
        .onChange(of: query) { selection = 0 }
        .onChange(of: isFocused) { _, focused in fieldFocused = focused }
        .onChange(of: fieldFocused) { _, focused in if focused { tab.focusedPaneID = picker.id } }
        .onAppear { if isFocused { DispatchQueue.main.async { fieldFocused = true } } }
    }

    private func row(_ option: PanePickerOption, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: option.symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent : Theme.selection))
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = option.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : Color.clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func pick(_ options: [PanePickerOption]) {
        guard options.indices.contains(selection) else { return }
        store.resolvePicker(picker.id, with: options[selection].choice)
    }
}
