import SwiftUI

@main
struct SimpleMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(version: readVersion())
        }
    }
}

func readVersion() -> String {
    if let url = Bundle.module.url(forResource: "VERSION", withExtension: nil),
       let s = try? String(contentsOf: url) {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "0.0.0"
}
