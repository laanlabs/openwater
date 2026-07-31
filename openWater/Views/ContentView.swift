import OpenWaterCore
import SwiftUI

struct ContentView: View {

    @Environment(PhoneRecorder.self) private var recorder

    @State private var selection: ScreenshotRoute.Tab = .sessions

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "list.bullet", value: ScreenshotRoute.Tab.sessions) {
                SessionListView()
            }
            Tab("Record", systemImage: "record.circle", value: ScreenshotRoute.Tab.record) {
                RecordTabView()
            }
            // A session runs for hours with the phone stowed, and a rider who
            // opened the app to look at something else has no other way to tell
            // it is still going.
            .badge(recorder.state == .idle ? nil : Text("REC"))
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
