import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 파일 목록 (로컬·원격 공용).
///
/// SwiftUI `List` 를 쓰지 않는다: macOS 의 List 는 내부 AppKit 표(NSOutlineView)가 끌어다 놓기를
/// 먼저 받아 `.onDrop` 이 호출되지 않는 문제가 있었다. (회귀: SFTP 에 파일을 끌어다 놓아도 반응 없음)
/// 대신 ScrollView + LazyVStack 으로 그리고 선택은 Finder 와 같게 직접 처리한다.
///
/// - 클릭: 하나만 선택 · ⌘클릭: 추가/빼기 · ⇧클릭: 범위 · 빈 곳 클릭: 선택 해제
/// - 더블클릭: primaryAction · 우클릭: 선택 항목(또는 그 행) 메뉴, 빈 곳 우클릭: 폴더 메뉴
struct FileListView<Item: Identifiable>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Set<Item.ID>
    let row: (Item) -> FileRowView
    /// 행을 끌 때 넘길 데이터 (nil 이면 끌 수 없음)
    let dragProvider: (Item) -> NSItemProvider?
    let menu: ([Item]) -> AnyView
    let primaryAction: ([Item]) -> Void
    let dropTypes: [UTType]
    let onDrop: ([NSItemProvider]) -> Bool
    @Binding var dropTargeted: Bool

    @State private var anchor: Item.ID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    rowView(item)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        // 빈 곳: 클릭하면 선택 해제, 우클릭하면 폴더 메뉴
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection = [] }
                .contextMenu { menu([]) })
        .onDrop(of: dropTypes, isTargeted: $dropTargeted, perform: onDrop)
    }

    private func rowView(_ item: Item) -> some View {
        let selected = selection.contains(item.id)
        return row(item)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Theme.accent.opacity(0.28) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { click(item) }
            .contextMenu {
                // 선택된 행을 우클릭하면 선택 전체, 아니면 그 행만
                menu(selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item])
            }
            .onDrag { dragProvider(item) ?? NSItemProvider() }
    }

    private func click(_ item: Item) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []

        if event?.clickCount == 2 {
            primaryAction(selection.contains(item.id) && selection.count > 1
                ? items.filter { selection.contains($0.id) } : [item])
            return
        }

        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift),
                  let anchor, let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }
}
