SimpleMacApp

簡易原生 macOS SwiftUI 範例（不含 Xcode 專案）

快速上手

1. 在 macOS 12+ 與 Swift 5.7+ 環境下，打開 Terminal：

```bash
cd ~/Desktop/SimpleMacApp
swift build
swift run
```

2. 若要在 Xcode 中開啟（建議以圖形化編輯資源與簽章）：

- 在 Xcode 中選擇 `File > Open`，然後打開 `Package.swift`；或直接執行 `open Package.swift`。

說明

- `Package.swift`：Swift Package manifest，目標平台 macOS 12。
- `Sources/App`：應用程式原始碼（`main.swift`, `ContentView.swift`）。
- `Sources/App/Resources/VERSION`：範例版本檔，程式會讀取並在主視窗顯示。

下一步建議

- 我可以為你建立 Xcode 專案、加入偏好設定視窗、或新增菜單列圖示。
- 是否要我現在替你建立 git commit？（會使用繁體中文訊息，不會推到遠端）
