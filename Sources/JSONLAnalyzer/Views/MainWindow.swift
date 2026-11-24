import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } content: {
            RecordListView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560, max: .infinity)
        } detail: {
            DetailTabs()
                .navigationSplitViewColumnWidth(min: 420, ideal: 520, max: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(model.sessions)
        .environmentObject(model.records)
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first {
                model.open(url)
                return true
            }
            return false
        }
        .alert("提示", isPresented: Binding(
            get: { model.openError != nil },
            set: { if !$0 { model.openError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.openError ?? "")
        }
    }
}
