import AppKit
import SwiftUI

@main
struct MyTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()

    init() {
        // 저장된 설정으로 settings.conf 를 만든 뒤 libghostty 를 초기화한다 (첫 화면보다 먼저).
        PreferencesMigration.run()   // 번들 ID 변경 전 설정 옮기기 (설정을 읽기 전에)
        TerminalSettings.shared.writeConfigFile()
        RemoteEditor.cleanUpPreviousSession()
        _ = GhosttyRuntime.shared
    }

    /// 앱에 들어 있는 문서를 기본 앱(텍스트 편집기 등)으로 연다
    static func openBundled(_ name: String, _ ext: String?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some Scene {
        Window("MyTerminal", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(HostStore.shared)
                .environmentObject(store.history)
                .onAppear { appDelegate.store = store }
                .background(MainWindowHook(appDelegate: appDelegate))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            // 설정 메뉴(⌘,)는 아래 Settings 장면이 자동으로 만든다.
            CommandGroup(replacing: .newItem) {
                Button("새 로컬 터미널") { store.openLocalTerminal() }
                    .keyboardShortcut("t")
                Button("홈") { store.selectedTab = .home }
                    .keyboardShortcut("0")
                Divider()
                Button("화면 닫기") { store.closeCurrentPane() }
                    .keyboardShortcut("w")
                    .disabled(store.currentTab == nil)
                Button("탭 닫기") {
                    if let tab = store.currentTab { store.closeTab(tab.id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(store.currentTab == nil)
            }

            CommandMenu("화면") {
                Button("좌우로 분할") { store.splitCurrentPane(.horizontal) }
                    .keyboardShortcut("d")
                Button("위아래로 분할") { store.splitCurrentPane(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("다음 화면") { store.focusPane(offset: 1) }
                    .keyboardShortcut("]")
                Button("이전 화면") { store.focusPane(offset: -1) }
                    .keyboardShortcut("[")
                Button("화면 크기 균등하게") { store.equalizePanes() }
                    .keyboardShortcut("=", modifiers: [.command, .control])
                Button("이 화면을 새 탭으로 분리") { store.detachCurrentPane() }
                    .disabled(!store.canDetachCurrentPane)
                Divider()
                Button("파일 패널 보이기·숨기기") { store.toggleFilePanel() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("화면 지우기") { store.clearCurrentScreen() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(store.currentTab == nil)
            }

            CommandGroup(replacing: .help) {
                Button("MyTerminal 도움말 (GitHub)") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/choiseungyun/MyTerminal#readme")!)
                }
                Button("오픈소스 라이선스") { Self.openBundled("THIRD_PARTY_NOTICES", "md") }
                Button("MyTerminal 라이선스 (MIT)") { Self.openBundled("LICENSE", nil) }
            }

            CommandMenu("AI") {
                Button("명령 추천…") { store.openAIPalette() }
                    .keyboardShortcut("k")
                    .disabled(store.currentTab == nil)
                Button("선택한 내용·화면 설명") { store.explainWithAI() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.currentTab == nil)
                Button("접속 실패 진단") {
                    if let tab = store.currentTab { store.diagnoseConnection(tab.focusedPaneID) }
                }
                .disabled(!store.canDiagnoseConnection)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 메인 창을 AppDelegate 에 연결한다 (닫기 버튼 → 종료 절차, 다시 열기 동작)
private struct MainWindowHook: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowConnector(appDelegate: appDelegate) { openWindow(id: "main") }
            .frame(width: 0, height: 0)
    }
}
