import SwiftUI

struct ContentView: View {
    let version: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Simple Mac App")
                .font(.largeTitle)
            Text("版本: \(version)")
                .font(.subheadline)
            Button("設定") {
                // TODO: 開啟設定視窗或面板
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(version: "0.1.0")
    }
}
#endif
