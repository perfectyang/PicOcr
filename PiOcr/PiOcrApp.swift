//
//  PiOcrApp.swift
//  PiOcr
//
//  Created by perfectyang on 2026/10/9.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct PiOcrApp: App {
    @State private var model: PiOcrModel
    @State private var shortcuts: PiOcrGlobalShortcuts

    init() {
        let model = PiOcrModel()
        _model = State(initialValue: model)
        _shortcuts = State(initialValue: PiOcrGlobalShortcuts(model: model))
    }

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
        Button("区域截图并编辑") { model.startCapture() }
        Divider()
        Button("打开 PiOcr") { openWindow(id: "main") }
        Button("退出 PiOcr") { NSApp.terminate(nil) }
    }
}

@MainActor
private final class PiOcrGlobalShortcuts {
    private let model: PiOcrModel
    private var eventHandler: EventHandlerRef?
    private var recognizeHotKey: EventHotKeyRef?
    private var editHotKey: EventHotKeyRef?

    init(model: PiOcrModel) {
        self.model = model

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let shortcuts = Unmanaged<PiOcrGlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in shortcuts.handle(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        guard installStatus == noErr else {
            NSLog("PiOcr: could not install global shortcut handler (%d)", installStatus)
            return
        }

        register(keyCode: UInt32(kVK_ANSI_1), id: 1, reference: &recognizeHotKey)
        register(keyCode: UInt32(kVK_ANSI_2), id: 2, reference: &editHotKey)
    }

    deinit {
        if let recognizeHotKey { UnregisterEventHotKey(recognizeHotKey) }
        if let editHotKey { UnregisterEventHotKey(editHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func register(keyCode: UInt32, id: UInt32, reference: inout EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x50694F63), id: id)
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status != noErr {
            NSLog("PiOcr: could not register Control+%u (%d)", id, status)
        }
    }

    private func handle(_ id: UInt32) {
        switch id {
        case 1:
            model.startCapture(recognize: true)
        case 2:
            model.startCapture()
        default:
            break
        }
    }
}
