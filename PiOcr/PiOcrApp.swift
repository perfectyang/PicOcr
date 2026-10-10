//
//  PiOcrApp.swift
//  PiOcr
//
//  Created by perfectyang on 2026/10/9.
//

import SwiftUI

@main
struct PiOcrApp: App {
    @State private var model = PiOcrModel()

    var body: some Scene {
        MenuBarExtra("PiOcr", systemImage: "viewfinder") {
            PiOcrMenu(model: model)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup(id: "main") {
            ContentView().environment(model)
        }
        .defaultSize(width: 400, height: 260)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct PiOcrMenu: View {
    @Environment(\.openWindow) private var openWindow
    let model: PiOcrModel

    var body: some View {
        Button("区域截图识别并复制文字") { model.startCapture(recognize: true) }
            .keyboardShortcut("2", modifiers: [.command, .shift])
        Button("区域截图并编辑") { model.startCapture() }
            .keyboardShortcut("4", modifiers: [.command, .shift])
        Divider()
        Button("打开 PiOcr") { openWindow(id: "main") }
        Button("退出 PiOcr") { NSApp.terminate(nil) }
    }
}
