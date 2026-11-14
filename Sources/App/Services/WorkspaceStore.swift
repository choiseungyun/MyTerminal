import Foundation
import SwiftUI

/// 위쪽 탭 바의 탭 종류
enum WorkspaceTab: Hashable {
    case home
    case sftp
    case terminal(UUID)
}

/// 터미널 화면(pane) 하나 = 셸 세션 하나. 화면(NSView)이 탭 전환·분할에도 유지되도록 여기서 소유한다.
final class TerminalPane: ObservableObject, Identifiable {
    let id = UUID()
    let view: TerminalSurfaceView
    /// ssh 접속 정보 (로컬 터미널이면 nil)
    let target: SSHLaunch?

    @Published var title: String
    @Published var pwd: String?

    /// 비밀번호 자동 입력 토큰 (화면이 사라지면 폐기)
    private var askpassToken: String?
    /// 접속 이력 id (SSH 화면만)
    var historyID: UUID?

    /// 셸 통합이 알려 준 마지막 명령의 실패 종료 코드 (성공하면 nil). "왜 실패했나요?" 버튼에 쓴다.
    @Published var lastFailedExitCode: Int?
    /// SSH 접속이 오류로 끝난 종료 코드 ("접속 실패 진단" 버튼에 쓴다)
    @Published var connectionFailure: Int32?

    /// AI 에 보내는 이 화면 정보
    var aiContext: AIPaneContext { AIPaneContext(target: target, directory: pwd) }

    /// 이 화면 서버의 파일 탐색기 (SSH 화면만, 파일 패널을 처음 열 때 만든다)
    @MainActor lazy var fileBrowser: RemoteBrowser? = target.map { RemoteBrowser(launch: $0) }

    init(target: SSHLaunch?, workingDirectory: String? = nil) {
        self.target = target
        self.title = target?.title ?? "로컬"

        var options = TerminalSurfaceView.Options()
        if let target {
            // 실제 종료 코드를 남기도록 감싼다 (정상 로그아웃이면 화면을 닫기 위해)
            options.command = ExitStatus.wrap(target.commandLine)
            options.environment[ExitStatus.environmentKey] = ExitStatus.fileURL(for: id).path
            // 접속 실패 등 오류로 끝나면 메시지를 볼 수 있게 기다린다 (정상 종료는 앱이 바로 닫음)
            options.waitAfterCommand = true
            // 원격 서버에는 xterm-ghostty terminfo 가 없는 경우가 많아 범용 값을 쓴다.
            // (없으면 백스페이스·색상·전체 화면 프로그램이 깨진다)
            options.environment["TERM"] = "xterm-256color"
            // 저장된 비밀번호 자동 입력 (SSH_ASKPASS)
            if let askpass = AskpassServer.shared.environment(for: target) {
                options.environment.merge(askpass.environment) { _, new in new }
                askpassToken = askpass.token
            }
        } else {
            options.workingDirectory = workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        self.view = TerminalSurfaceView(options: options)

        view.onTitleChange = { [weak self] title in self?.title = title }
        view.onPwdChange = { [weak self] pwd in self?.pwd = pwd }
    }

    deinit {
        if let askpassToken { AskpassServer.shared.unregister(askpassToken) }
        try? FileManager.default.removeItem(at: ExitStatus.fileURL(for: id))
    }

    /// ssh 의 실제 종료 코드 (로컬 화면이거나 기록이 없으면 nil)
    var exitStatus: Int32? {
        target == nil ? nil : ExitStatus.read(ExitStatus.fileURL(for: id))
    }

    /// 같은 대상으로 새 화면을 만든다 (분할용). 로컬이면 현재 디렉터리에서 시작한다.
    func sibling() -> TerminalPane {
        TerminalPane(target: target, workingDirectory: pwd)
    }
}

/// 분할 칸에서 아직 접속 대상을 고르지 않은 상태 (⌘D 직후).
/// 대상을 고르면 그 자리가 터미널 화면으로 바뀐다.
struct PanePicker: Identifiable {
    let id = UUID()
    /// 분할을 시작한 화면의 접속 대상 ("같은 서버"용, 로컬이면 nil)
    let originTarget: SSHLaunch?
    /// 분할을 시작한 화면의 현재 디렉터리 (로컬 터미널 시작 위치)
    let originDirectory: String?
}

/// 분할 칸 하나: 터미널 화면 또는 대상 선택 중인 칸
enum PaneLeaf: Identifiable {
    case terminal(TerminalPane)
    case picker(PanePicker)

    var id: UUID {
        switch self {
        case .terminal(let pane): pane.id
        case .picker(let picker): picker.id
        }
    }

    var terminal: TerminalPane? {
        if case .terminal(let pane) = self { return pane }
        return nil
    }
}

/// 분할 칸에서 고른 접속 대상
enum PaneChoice {
    /// 분할을 시작한 화면과 같은 대상
    case same
    case local
    case host(SSHHost)
    case quick(QuickConnectTarget)
}

extension SplitTree where Leaf == PaneLeaf {
    func splitting(_ paneID: UUID, with pane: TerminalPane, axis: SplitAxis) -> SplitTree {
        splitting(paneID, with: .terminal(pane), axis: axis)
    }
}

/// 탭 끌기 좌표계: 창 내용 전체(MainView). 마우스 위치와 칸·탭 이름 위치를 같은 기준으로 잰다.
let workspaceCoordinateSpace = "workspace"

/// 탭을 놓을 칸과 가장자리
struct PaneDropTarget: Equatable {
    let paneID: UUID
    let edge: DropEdge
}

/// 탭 바에서 탭을 끄는 중인 상태
struct TabDrag: Equatable {
    let sourceTabID: UUID
    /// 마우스 위치 (workspace 좌표)
    let location: CGPoint
    let target: PaneDropTarget?
}

/// 터미널 탭 하나. 안에 분할된 화면들을 가진다.
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var root: PaneTree
    /// 포커스된 칸 (터미널 또는 대상 선택 칸)
    @Published var focusedPaneID: UUID
    /// 오른쪽 파일(SFTP) 패널을 보이는지
    @Published var showsFilePanel = false

    init(pane: TerminalPane) {
        root = .leaf(.terminal(pane))
        focusedPaneID = pane.id
    }

    /// 왼쪽 위부터 모든 칸 (선택 중인 칸 포함)
    var leaves: [PaneLeaf] { root.panes }

    /// 터미널 화면만
    var panes: [TerminalPane] { leaves.compactMap(\.terminal) }

    /// 포커스된 터미널 화면. 선택 중인 칸에 포커스가 있으면 첫 터미널 화면.
    var focusedPane: TerminalPane? {
        panes.first { $0.id == focusedPaneID } ?? panes.first
    }
}

/// 검색창에 입력한 접속 대상. 예: "deploy@web-01", "ssh -p 2222 admin@10.0.0.5"
struct QuickConnectTarget: Hashable, Identifiable {
    let raw: String
    var id: String { raw }

    /// ssh 에 넘길 인자 (앞의 "ssh " 는 떼어 낸다)
    var arguments: String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ssh ") { return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return trimmed
    }

    var sshCommand: String { "ssh \(arguments)" }

    /// user@host 에서 host 부분 (카드 제목, 탭 제목용)
    var host: String {
        let dest = arguments.split(separator: " ").last.map(String.init) ?? arguments
        return dest.split(separator: "@").last.map(String.init) ?? dest
    }

    var user: String? {
        let dest = arguments.split(separator: " ").last.map(String.init) ?? arguments
        let parts = dest.split(separator: "@")
        return parts.count == 2 ? String(parts[0]) : nil
    }

    var displayName: String { host }

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "ssh" else { return nil }
        self.raw = trimmed
    }
}

/// 창 하나의 상태: 열린 탭, 선택된 탭, 최근 접속
final class WorkspaceStore: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTab: WorkspaceTab = .home {
        didSet {
            guard case .terminal(let id) = selectedTab, id != lastTerminalTabID else { return }
            previousTerminalTabID = lastTerminalTabID
            lastTerminalTabID = id
        }
    }
    /// 가장 최근에 본 터미널 탭 (홈에서 "분할로 열기" 대상)
    private var lastTerminalTabID: UUID?
    /// 그 전에 본 터미널 탭 (탭을 끌기 시작할 때 자동으로 보여 줄 탭)
    private var previousTerminalTabID: UUID?
    /// 이번 실행에서 빠른 연결한 대상
    @Published var recentTargets: [QuickConnectTarget] = []

    /// 접속 이력 (테스트에서는 메모리 데이터베이스를 넣는다)
    let history: HistoryStore
    private var sftpHistoryID: UUID?

    init(history: HistoryStore = .shared) {
        self.history = history
    }

    // MARK: 탭

    func openLocalTerminal() {
        open(TerminalTab(pane: register(TerminalPane(target: nil))))
    }

    func connect(_ target: QuickConnectTarget) {
        recentTargets.removeAll { $0 == target }
        recentTargets.insert(target, at: 0)
        open(TerminalTab(pane: register(TerminalPane(target: SSHCommand.launch(for: target)))))
    }

    /// 저장된 호스트에 새 탭으로 접속한다.
    /// showFiles: 접속과 함께 오른쪽 파일(SFTP) 패널을 연다
    func connect(_ host: SSHHost, showFiles: Bool = false) {
        HostStore.shared.markConnected(host.id)
        let tab = TerminalTab(pane: register(TerminalPane(target: SSHCommand.launch(for: host))))
        tab.showsFilePanel = showFiles
        open(tab)
    }

    /// 저장된 호스트를 가장 최근 터미널 탭의 현재 화면 옆에 분할로 연다. 터미널 탭이 없으면 새 탭.
    func connectInSplit(_ host: SSHHost, axis: SplitAxis = .horizontal) {
        guard let tab = lastTerminalTabID.flatMap(self.tab), let pane = tab.focusedPane else {
            connect(host)
            return
        }
        HostStore.shared.markConnected(host.id)
        let newPane = register(TerminalPane(target: SSHCommand.launch(for: host)))
        tab.root = tab.root.splitting(pane.id, with: newPane, axis: axis)
        tab.focusedPaneID = newPane.id
        selectedTab = .terminal(tab.id)
    }

    /// 분할로 열 수 있는 터미널 탭이 있는지 (메뉴 표시용)
    var hasTerminalTab: Bool { lastTerminalTabID.flatMap(tab) != nil }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].panes.forEach(endHistory)
        tabs.remove(at: index)
        if selectedTab == .terminal(id) {
            selectedTab = tabs.isEmpty ? .home : .terminal(tabs[min(index, tabs.count - 1)].id)
        }
    }

    func tab(_ id: UUID) -> TerminalTab? {
        tabs.first { $0.id == id }
    }

    var currentTab: TerminalTab? {
        if case .terminal(let id) = selectedTab { return tab(id) }
        return nil
    }

    private func open(_ tab: TerminalTab) {
        tabs.append(tab)
        selectedTab = .terminal(tab.id)
    }

    // MARK: 화면 분할

    /// 현재 화면을 나눈다. (⌘D 좌우, ⇧⌘D 위아래)
    /// choice 가 nil 이면 새 칸에서 접속 대상을 고르게 하고, 주어지면 바로 연다.
    func splitCurrentPane(_ axis: SplitAxis, choice: PaneChoice? = nil) {
        guard let tab = currentTab,
              let leaf = tab.leaves.first(where: { $0.id == tab.focusedPaneID }) ?? tab.leaves.first
        else { return }

        let picker: PanePicker
        switch leaf {
        case .terminal(let pane): picker = PanePicker(originTarget: pane.target, originDirectory: pane.pwd)
        case .picker(let other): picker = PanePicker(originTarget: other.originTarget, originDirectory: other.originDirectory)
        }

        let newLeaf: PaneLeaf = choice.map { .terminal(makePane($0, from: picker)) } ?? .picker(picker)
        tab.root = tab.root.splitting(leaf.id, with: newLeaf, axis: axis)
        tab.focusedPaneID = newLeaf.id
    }

    /// 대상 선택 칸에서 고른 대상으로 터미널을 연다. 칸 위치는 그대로.
    func resolvePicker(_ pickerID: UUID, with choice: PaneChoice) {
        guard let tab = tabs.first(where: { $0.root.contains(pickerID) }),
              case .picker(let picker)? = tab.leaves.first(where: { $0.id == pickerID }) else { return }
        let pane = makePane(choice, from: picker)
        tab.root = tab.root.replacing(pickerID, with: .terminal(pane))
        if tab.focusedPaneID == pickerID { tab.focusedPaneID = pane.id }
    }

    /// 고른 대상으로 새 화면을 만든다.
    private func makePane(_ choice: PaneChoice, from picker: PanePicker) -> TerminalPane {
        let pane: TerminalPane
        switch choice {
        case .same:
            pane = TerminalPane(target: picker.originTarget, workingDirectory: picker.originDirectory)
        case .local:
            // 로컬 화면에서 나눴으면 그 디렉터리에서, 서버 화면이었으면 홈에서 시작
            pane = TerminalPane(target: nil, workingDirectory: picker.originTarget == nil ? picker.originDirectory : nil)
        case .host(let host):
            HostStore.shared.markConnected(host.id)
            pane = TerminalPane(target: SSHCommand.launch(for: host))
        case .quick(let target):
            recentTargets.removeAll { $0 == target }
            recentTargets.insert(target, at: 0)
            pane = TerminalPane(target: SSHCommand.launch(for: target))
        }
        return register(pane)
    }

    /// 현재 화면을 닫는다. 탭의 마지막 화면이면 탭을 닫는다. (⌘W)
    func closeCurrentPane() {
        guard let tab = currentTab else { return }
        closePane(tab.focusedPaneID)
    }

    func closePane(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.root.contains(paneID) }) else { return }
        guard tab.root.removing(paneID) != nil else {
            closeTab(tab.id)
            return
        }
        tab.panes.first { $0.id == paneID }.map(endHistory)
        remove(paneID, from: tab)
    }

    /// 칸을 트리에서 빼고, 포커스가 있었다면 앞 칸으로 옮긴다. (마지막 칸이 아니어야 한다)
    private func remove(_ paneID: UUID, from tab: TerminalTab) {
        let order = tab.leaves.map(\.id)
        guard let newRoot = tab.root.removing(paneID) else { return }
        tab.root = newRoot
        if tab.focusedPaneID == paneID || !newRoot.contains(tab.focusedPaneID) {
            let index = order.firstIndex(of: paneID) ?? 0
            let remaining = newRoot.panes
            tab.focusedPaneID = remaining[max(0, min(index - 1, remaining.count - 1))].id
        }
    }

    // MARK: AI

    /// AI 화면 상태 (처음 쓸 때 만든다)
    lazy var ai = AIAssistant()

    /// 포커스된 화면 (선택 칸이면 nil)
    private var focusedTerminal: (tab: TerminalTab, pane: TerminalPane)? {
        guard let tab = currentTab, let pane = tab.panes.first(where: { $0.id == tab.focusedPaneID }) else { return nil }
        return (tab, pane)
    }

    /// ⌘K 명령 추천 팔레트
    func openAIPalette() {
        guard let (tab, pane) = focusedTerminal else { return }
        ai.closePanel()
        ai.openPalette(tabID: tab.id, paneID: pane.id, context: pane.aiContext, selection: pane.view.selectedText())
    }

    /// 선택한 글자를 설명한다. 선택이 없으면 실패한 명령, 그것도 없으면 지금 화면.
    func explainWithAI() {
        guard let (tab, pane) = focusedTerminal else { return }
        ai.closePalette()
        if let selection = pane.view.selectedText() {
            ai.explain(.selection, output: selection, context: pane.aiContext, tabID: tab.id, paneID: pane.id)
        } else if let code = pane.lastFailedExitCode {
            ai.explain(.failure(exitCode: code), output: pane.view.visibleText(), context: pane.aiContext, tabID: tab.id, paneID: pane.id)
        } else {
            ai.explain(.screen, output: pane.view.visibleText(), context: pane.aiContext, tabID: tab.id, paneID: pane.id)
        }
    }

    /// 실패한 명령 설명 (상태 줄 "왜 실패했나요?")
    func explainFailure(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.root.contains(paneID) }),
              let pane = tab.panes.first(where: { $0.id == paneID }), let code = pane.lastFailedExitCode else { return }
        ai.closePalette()
        ai.explain(.failure(exitCode: code), output: pane.view.visibleText(), context: pane.aiContext, tabID: tab.id, paneID: pane.id)
    }

    /// SSH 접속 실패 진단
    func diagnoseConnection(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.root.contains(paneID) }),
              let pane = tab.panes.first(where: { $0.id == paneID }), let code = pane.connectionFailure else { return }
        ai.closePalette()
        let host = pane.target?.hostID.flatMap { HostStore.shared.host($0) }
        ai.diagnose(output: pane.view.visibleText(), exitCode: code, host: host,
                    context: pane.aiContext, tabID: tab.id, paneID: pane.id)
    }

    /// 화면에 키 입력 포커스를 돌려준다 (팔레트를 닫은 뒤)
    func focus(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.root.contains(paneID) }),
              let pane = tab.panes.first(where: { $0.id == paneID }) else { return }
        tab.focusedPaneID = paneID
        pane.view.window?.makeFirstResponder(pane.view)
    }

    /// 화면 지우기 (⇧⌘K)
    func clearCurrentScreen() {
        focusedTerminal?.pane.view.clearScreen()
    }

    /// 포커스된 화면이 접속 실패 상태인지 (메뉴 활성화)
    var canDiagnoseConnection: Bool { focusedTerminal?.pane.connectionFailure != nil }

    /// AI 가 제안한 명령을 화면 입력줄에 넣는다 (Enter 는 누르지 않는다).
    /// 끝난 화면(접속 실패 등)이면 새 로컬 터미널을 열어 넣는다.
    func insertCommand(_ command: String, into paneID: UUID) {
        let single = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty, !single.contains("\n") else { return }

        if let tab = tabs.first(where: { $0.root.contains(paneID) }),
           let pane = tab.panes.first(where: { $0.id == paneID }), pane.connectionFailure == nil {
            selectedTab = .terminal(tab.id)
            tab.focusedPaneID = pane.id
            pane.view.sendText(single)
            pane.view.window?.makeFirstResponder(pane.view)
        } else {
            openLocalTerminal()
            // 셸이 뜬 뒤 입력되도록 조금 기다린다 (입력은 터미널 버퍼에 쌓여 있다가 셸이 읽는다)
            guard let pane = currentTab?.panes.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pane.view.sendText(single) }
        }
    }

    // MARK: 탭 합치기·분리

    /// 탭 바에서 끌고 있는 탭과 놓을 곳 (끌고 있지 않으면 nil)
    @Published private(set) var tabDrag: TabDrag?
    /// 칸·탭 이름의 창 안 위치(workspace 좌표). 끌 때 놓을 곳을 찾는 데만 쓰므로 화면 갱신을 일으키지 않는다.
    var paneFrames: [UUID: CGRect] = [:]
    var tabChipFrames: [UUID: CGRect] = [:]

    /// 끌기를 시작할 때 보던 탭 (합치지 않고 끝나면 돌아간다)
    private var tabDragStartSelection: WorkspaceTab?

    /// 탭을 끄는 중: 다른 탭 이름 위면 그 탭으로 전환, 보이는 탭의 칸 위면 놓을 가장자리를 정한다.
    func updateTabDrag(_ sourceTabID: UUID, at location: CGPoint) {
        guard tab(sourceTabID) != nil else {
            tabDrag = nil
            return
        }
        if tabDrag == nil {
            tabDragStartSelection = selectedTab
            // 보고 있는 탭을 끌기 시작하면 자기 화면에는 놓을 수 없으므로 바로 전에 보던 탭을 보여 준다
            if selectedTab == .terminal(sourceTabID), let other = mergeCandidate(for: sourceTabID) {
                selectedTab = .terminal(other)
            }
        }
        if let hovered = tabChipFrames.first(where: { $0.key != sourceTabID && $0.value.contains(location) })?.key,
           tab(hovered) != nil, selectedTab != .terminal(hovered) {
            selectedTab = .terminal(hovered)
        }

        var target: PaneDropTarget?
        if let tab = currentTab, tab.id != sourceTabID {
            for leaf in tab.leaves {
                guard let frame = paneFrames[leaf.id], frame.contains(location) else { continue }
                let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
                target = PaneDropTarget(paneID: leaf.id, edge: .nearest(to: point, in: frame.size))
                break
            }
        }
        tabDrag = TabDrag(sourceTabID: sourceTabID, location: location, target: target)
    }

    /// 끌기를 마친다. 칸 위에서 놓았으면 합친다.
    @discardableResult
    func endTabDrag() -> Bool {
        defer {
            tabDrag = nil
            // 닫힌 칸·탭의 위치 정보 정리
            let leafIDs = Set(tabs.flatMap { $0.leaves.map(\.id) })
            paneFrames = paneFrames.filter { leafIDs.contains($0.key) }
            let tabIDs = Set(tabs.map(\.id))
            tabChipFrames = tabChipFrames.filter { tabIDs.contains($0.key) }
        }
        let startSelection = tabDragStartSelection
        tabDragStartSelection = nil
        guard let drag = tabDrag, let target = drag.target,
              mergeTab(drag.sourceTabID, into: target.paneID, edge: target.edge) else {
            // 합치지 않았으면 끌기 전에 보던 탭으로 돌아간다
            if let startSelection { selectedTab = startSelection }
            return false
        }
        return true
    }

    /// 탭을 끌기 시작할 때 대신 보여 줄 탭: 바로 전에 본 탭, 없으면 이웃 탭
    private func mergeCandidate(for sourceTabID: UUID) -> UUID? {
        if let previous = previousTerminalTabID, previous != sourceTabID, tab(previous) != nil { return previous }
        guard let index = tabs.firstIndex(where: { $0.id == sourceTabID }) else { return nil }
        if index > 0 { return tabs[index - 1].id }
        return index + 1 < tabs.count ? tabs[index + 1].id : nil
    }

    /// `sourceTabID` 탭의 화면들(분할 배치 그대로)을 `paneID` 화면의 `edge` 쪽으로 옮겨 합친다.
    /// 접속은 끊지 않는다. 옮겨진 탭은 사라진다.
    @discardableResult
    func mergeTab(_ sourceTabID: UUID, into paneID: UUID, edge: DropEdge) -> Bool {
        guard let source = tab(sourceTabID),
              let target = tabs.first(where: { $0.root.contains(paneID) }),
              source !== target else { return false }

        target.root = target.root.inserting(source.root, at: paneID, axis: edge.axis, before: edge.placesBefore)
        target.focusedPaneID = source.root.contains(source.focusedPaneID) ? source.focusedPaneID : source.leaves[0].id
        if source.showsFilePanel { target.showsFilePanel = true }

        tabs.removeAll { $0 === source }
        selectedTab = .terminal(target.id)
        return true
    }

    /// 분할된 화면 하나를 새 탭으로 떼어 낸다. 접속은 끊지 않는다.
    @discardableResult
    func detachPane(_ paneID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.root.contains(paneID) }),
              tab.leaves.count > 1,
              let pane = tab.panes.first(where: { $0.id == paneID }) else { return false }
        remove(paneID, from: tab)

        let newTab = TerminalTab(pane: pane)
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            tabs.insert(newTab, at: index + 1)
        } else {
            tabs.append(newTab)
        }
        selectedTab = .terminal(newTab.id)
        return true
    }

    /// 현재 화면을 새 탭으로 (메뉴)
    func detachCurrentPane() {
        guard let tab = currentTab else { return }
        detachPane(tab.focusedPaneID)
    }

    /// 현재 화면을 새 탭으로 뗄 수 있는지 (메뉴 활성화)
    var canDetachCurrentPane: Bool {
        guard let tab = currentTab else { return false }
        return tab.leaves.count > 1 && tab.panes.contains { $0.id == tab.focusedPaneID }
    }

    /// 다음(+1) / 이전(-1) 화면으로 포커스 이동 (⌘] / ⌘[)
    func focusPane(offset: Int) {
        guard let tab = currentTab else { return }
        let panes = tab.leaves
        guard panes.count > 1, let index = panes.firstIndex(where: { $0.id == tab.focusedPaneID }) else { return }
        tab.focusedPaneID = panes[(index + offset + panes.count) % panes.count].id
    }

    // MARK: SFTP 탭

    /// SFTP 탭 오른쪽 칸의 원격 탐색기 (호스트를 고르기 전에는 nil)
    @Published var sftpRemote: RemoteBrowser?
    /// SFTP 탭 왼쪽 칸 (이 Mac)
    @MainActor lazy var sftpLocal = LocalBrowser()

    /// SFTP 탭에서 저장된 호스트를 연다.
    @MainActor
    func openSFTP(_ host: SSHHost) {
        HostStore.shared.markConnected(host.id)
        openSFTP(launch: SSHCommand.launch(for: host))
    }

    @MainActor
    func openSFTP(_ target: QuickConnectTarget) {
        openSFTP(launch: SSHCommand.launch(for: target))
    }

    @MainActor
    private func openSFTP(launch: SSHLaunch) {
        closeSFTPRemote()
        sftpRemote = RemoteBrowser(launch: launch)
        sftpHistoryID = history.start(launch, kind: .sftp)
        selectedTab = .sftp
    }

    /// 원격 칸을 닫고 호스트 고르기로 돌아간다.
    @MainActor
    func closeSFTPRemote() {
        sftpRemote?.disconnect()
        sftpRemote = nil
        if let sftpHistoryID { history.end(sftpHistoryID) }
        sftpHistoryID = nil
    }

    // MARK: 접속 이력

    /// 접속 이력에서 다시 접속: 저장된 호스트면 지금 설정으로, 아니면 기록된 인자로
    func reconnect(_ record: ConnectionRecord) {
        if let id = record.hostID, let host = HostStore.shared.host(id) {
            if record.kind == .sftp { Task { @MainActor in self.openSFTP(host) } } else { connect(host) }
        } else if let target = record.quickTarget {
            if record.kind == .sftp { Task { @MainActor in self.openSFTP(target) } } else { connect(target) }
        }
    }

    /// 지금 열려 있는 접속인지 (히스토리의 "접속 중" 표시)
    func isOpen(_ record: ConnectionRecord) -> Bool {
        record.id == sftpHistoryID || tabs.contains { $0.panes.contains { $0.historyID == record.id } }
    }

    /// 앱을 끝낼 때: 열린 접속을 모두 끝난 것으로 기록
    func endAllHistory() {
        history.endAllOpen()
    }

    private func endHistory(_ pane: TerminalPane) {
        guard let id = pane.historyID else { return }
        history.end(id)
        pane.historyID = nil
    }

    /// 오른쪽 파일 패널 보이기·숨기기 (⌥⌘F)
    func toggleFilePanel() {
        guard let tab = currentTab else { return }
        withAnimation(.easeOut(duration: 0.2)) { tab.showsFilePanel.toggle() }
    }

    /// 분할 크기를 균등하게 (⌃⌘=)
    func equalizePanes() {
        guard let tab = currentTab else { return }
        tab.root = tab.root.equalized()
    }

    /// 화면의 포커스·종료 이벤트를 store 에 연결한다.
    private func register(_ pane: TerminalPane) -> TerminalPane {
        let paneID = pane.id
        if let target = pane.target { pane.historyID = history.start(target, kind: .ssh) }
        pane.view.onClose = { [weak self] in self?.closePane(paneID) }
        // SSH 화면이 끝났을 때: 정상 로그아웃(종료 코드 0)이면 화면을 바로 닫고,
        // 오류로 끝났으면 엔진이 "Process exited…" 를 보여 주고 키 입력을 기다린다.
        pane.view.onChildExited = { [weak self, weak pane] _, _ in
            guard let pane, pane.target != nil else { return false }
            guard pane.exitStatus == 0 else {
                // 오류로 끝난 접속: 메시지를 남기고 "접속 실패 진단" 버튼을 보인다
                let status = pane.exitStatus
                DispatchQueue.main.async { pane.connectionFailure = status ?? -1 }
                return false
            }
            DispatchQueue.main.async { self?.closePane(paneID) }
            return true
        }
        pane.view.onCommandFinished = { [weak pane] code in
            guard let pane else { return }
            let failed = code.flatMap { $0 > 0 ? $0 : nil }
            if pane.lastFailedExitCode != failed { pane.lastFailedExitCode = failed }
        }
        pane.view.onFocus = { [weak self] in
            guard let tab = self?.tabs.first(where: { $0.root.contains(paneID) }),
                  tab.focusedPaneID != paneID else { return }
            tab.focusedPaneID = paneID
        }
        return pane
    }
}
