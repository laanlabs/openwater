import OpenWaterCore
import SwiftUI

struct ContentView: View {

    @State private var selection: ScreenshotRoute.Tab = .sessions

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "list.bullet", value: ScreenshotRoute.Tab.sessions) {
                SessionListView()
            }
            Tab("Record", systemImage: "record.circle", value: ScreenshotRoute.Tab.record) {
                RecordTabView()
            }
            Tab("Bests", systemImage: "trophy", value: ScreenshotRoute.Tab.records) {
                RecordsView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: ScreenshotRoute.Tab.trends) {
                TrendsView()
            }
            Tab("Settings", systemImage: "gearshape", value: ScreenshotRoute.Tab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            if let route = ScreenshotRoute.requested { selection = route.tab }
        }
    }
}
