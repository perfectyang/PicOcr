//
//  ContentView.swift
//  PiOcr
//

import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

private let screenshotEditorToolbarHeight: CGFloat = 76

@MainActor
private final class ScreenshotEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
@Observable
final class PiOcrModel {
    var screenshot: NSImage?
    var recognizedText = ""
    var isRecognizing = false
    private var editorPanels: [UUID: NSPanel] = [:]
    private var dimPanels: [UUID: NSPanel] = [:]
    private var selectionPanels: [UUID: NSPanel] = [:]

    private func captureFullDisplay(_ screen: NSScreen) async throws -> NSImage {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = shareableContent.displays.first(where: { $0.displayID == screenNumber })
                ?? shareableContent.displays.first else {
            throw NSError(domain: "PiOcr.ScreenCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有找到当前显示器"])
        }

        let ownApplication = shareableContent.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let pixelScale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int((CGFloat(display.width) * pixelScale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * pixelScale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: image, size: screen.frame.size)
    }

    func startCapture(recognize: Bool = false) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            showMessage("无法开始截图", detail: "没有找到鼠标所在的显示器。")
            return
        }

        recognizedText = ""
        Task {
            var captures: [(image: NSImage, screen: NSScreen)] = []
            var lastCaptureError: Error?
            for screen in screens {
                do {
                    let image = try await captureFullDisplay(screen)
                    captures.append((image, screen))
                } catch {
                    lastCaptureError = error
                }
            }
            guard !captures.isEmpty else {
                let detail = lastCaptureError?.localizedDescription ?? "没有找到可用的显示器截图。"
                showMessage("无法捕获屏幕", detail: "请在系统设置的“隐私与安全性 > 屏幕录制”中允许 PiOcr，然后重新打开应用。\n\n\(detail)")
                return
            }
            for capture in captures {
                screenshot = capture.image
                showSelectionCanvas(capture.image, on: capture.screen, recognize: recognize)
            }
        }
    }

    private func closeSelectionCanvases() {
        for panel in selectionPanels.values { panel.close() }
        selectionPanels.removeAll()
    }

    private func showSelectionCanvas(_ image: NSImage, on screen: NSScreen, recognize: Bool) {
        let panel = CaptureSelectionPanel(contentRect: screen.frame,
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let id = UUID()
        panel.contentView = NSHostingView(rootView: SelectionCanvasView(
            image: image,
            recognize: recognize,
            onSelection: { [weak self] rect in
                guard let self else { return }
                guard rect.width >= 2, rect.height >= 2 else { return }
                self.closeSelectionCanvases()
                guard let cropImage = self.cropImage(image, rect: rect, on: screen) else { return }
                self.screenshot = cropImage
                self.recognizeText()
            },
            onAction: { [weak self] rect, action, cropImage in
                guard let self else { return }
                self.closeSelectionCanvases()
                self.screenshot = cropImage

                let globalRect = CGRect(
                    x: screen.frame.minX + rect.minX,
                    y: screen.frame.maxY - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                switch action {
                case .pin:
                    guard let editorID = self.showEditor(at: globalRect, on: screen) else { return }
                    self.pinEditor(editorID, image: cropImage)
                case .copy:
                    _ = self.copyImage(cropImage)
                case .save:
                    guard let editorID = self.showEditor(at: globalRect, on: screen) else { return }
                    self.saveImage(cropImage, from: editorID)
                }
            },
            onCancel: { [weak self] in
                self?.closeSelectionCanvases()
            }
        ))
        selectionPanels[id] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func cropImage(_ image: NSImage, rect: CGRect, on screen: NSScreen) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scaleX = CGFloat(cgImage.width) / max(screen.frame.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(screen.frame.height, 1)
        let cropRect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                              width: rect.width * scaleX, height: rect.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let crop = cgImage.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: crop, size: rect.size)
    }

    @discardableResult
    func showEditor(at selectedRect: CGRect, on screen: NSScreen) -> UUID? {
        guard let screenshot else { return nil }
        let toolbarHeight = screenshotEditorToolbarHeight
        let panelWidth = max(1, selectedRect.width)
        let panelHeight = selectedRect.height + toolbarHeight
        let origin = CGPoint(
            x: selectedRect.minX,
            y: selectedRect.minY - toolbarHeight
        )
        let panelFrame = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))
        let panelID = UUID()
        let dimPanel = NSPanel(contentRect: screen.frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        dimPanel.isOpaque = false
        dimPanel.backgroundColor = .clear
        dimPanel.hasShadow = false
        dimPanel.ignoresMouseEvents = true
        dimPanel.level = .floating
        dimPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dimPanel.contentView = NSHostingView(rootView: SelectionDimOverlay(screenFrame: screen.frame, selectionRect: selectedRect))
        dimPanels[panelID] = dimPanel
        dimPanel.orderFrontRegardless()

        let panel = ScreenshotEditorPanel(contentRect: panelFrame,
                                          styleMask: [.borderless],
                                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScreenshotEditorView(
            model: self,
            image: screenshot,
            selectionSize: selectedRect.size,
            panelID: panelID
        ))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        editorPanels[panelID] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return panelID
    }

    func closeEditor(_ id: UUID) {
        editorPanels[id]?.close()
        editorPanels[id] = nil
        dimPanels[id]?.close()
        dimPanels[id] = nil
    }

    func pinEditor(_ id: UUID, image: NSImage) {
        guard let panel = editorPanels[id] else { return }
        let availableWidth = max(1, panel.frame.width)
        let availableHeight = max(1, panel.frame.height - screenshotEditorToolbarHeight)
        let scale = min(
            availableWidth / max(image.size.width, 1),
            availableHeight / max(image.size.height, 1)
        )
        let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageFrame = CGRect(
            x: panel.frame.minX + (availableWidth - imageSize.width) / 2,
            y: panel.frame.minY + screenshotEditorToolbarHeight + (availableHeight - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        panel.contentView = NSHostingView(rootView: PinnedScreenshotView(
            image: image,
            panelID: id,
            model: self,
            displaySize: imageSize,
            onClose: { [weak self] in self?.closeEditor(id) }
        ))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.setFrame(imageFrame, display: true, animate: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        dimPanels[id]?.close()
        dimPanels[id] = nil
        panel.makeKeyAndOrderFront(nil)
    }

    func resizePinnedEditor(_ id: UUID, to size: CGSize, anchoredAt cursor: CGPoint? = nil) {
        guard let panel = editorPanels[id] else { return }
        var origin = panel.frame.origin
        if let cursor {
            let ratio = size.width / max(panel.frame.width, 1)
            origin.x += cursor.x * (1 - ratio)
            origin.y += cursor.y * (1 - ratio)
        }
        panel.setFrame(
            CGRect(origin: origin, size: size),
            display: true,
            animate: false
        )
    }

    func isEditorWindow(_ id: UUID, windowNumber: Int) -> Bool {
        editorPanels[id]?.windowNumber == windowNumber
    }

    func recognizeText() {
        guard let image = screenshot, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        isRecognizing = true
        recognizedText = "正在识别…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: String
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                result = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            } catch {
                result = "识别失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self?.recognizedText = result.isEmpty ? "没有识别到文字" : result
                self?.isRecognizing = false
                if !result.isEmpty, !result.hasPrefix("识别失败：") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }
            }
        }
    }

    @discardableResult
    func copyImage(_ image: NSImage) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }

    func saveImage(_ image: NSImage, from editorID: UUID) {
        guard let editorWindow = editorPanels[editorID] else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "PiOcr 截图.png"
        savePanel.beginSheetModal(for: editorWindow) { [weak self] response in
            guard let self, response == .OK,
                  let url = savePanel.url,
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            do {
                try png.write(to: url)
                self.closeEditor(editorID)
            } catch {
                self.showMessage("保存失败", detail: error.localizedDescription)
            }
        }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

private struct SelectionDragInput: NSViewRepresentable {
    let onStart: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: (CGPoint) -> Void

    func makeNSView(context: Context) -> SelectionDragNSView {
        let view = SelectionDragNSView()
        view.onStart = onStart
        view.onMove = onMove
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: SelectionDragNSView, context: Context) {
        view.onStart = onStart
        view.onMove = onMove
        view.onEnd = onEnd
    }
}

private final class SelectionDragNSView: NSView {
    var onStart: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let location = point(for: event)
        onStart?(location)
        onMove?(location)
    }

    override func mouseDragged(with event: NSEvent) {
        onMove?(point(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?(point(for: event))
    }
}

private struct SelectionDimOverlay: View {
    let screenFrame: CGRect
    let selectionRect: CGRect

    var body: some View {
        Canvas { context, size in
            let selection = CGRect(
                x: selectionRect.minX - screenFrame.minX,
                y: screenFrame.maxY - selectionRect.maxY,
                width: selectionRect.width,
                height: selectionRect.height
            )
            var mask = Path()
            mask.addRect(CGRect(origin: .zero, size: size))
            mask.addRect(selection)
            context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SelectionAction {
    case pin, copy, save
}

private struct SelectionCanvasView: View {
    let image: NSImage
    let recognize: Bool
    let onSelection: (CGRect) -> Void
    let onAction: (CGRect, SelectionAction, NSImage) -> Void
    let onCancel: () -> Void

    @State private var selection: CGRect?
    @State private var dragOrigin: CGPoint?
    @State private var selectionAtDragStart: CGRect?
    @State private var selectedTool: MarkupTool?
    @State private var selectedColor: Color = .red
    @State private var selectedFontSize: CGFloat = 24
    @State private var markups: [Markup] = []
    @State private var draft: Markup?
    @State private var textEntryPosition: CGPoint?
    @State private var annotationText = ""
    @State private var editingMarkupID: UUID?
    @State private var editingMarkupColor: Color?
    @State private var movingMarkupID: UUID?
    @State private var movingMarkupOrigin: CGPoint?
    @FocusState private var textFieldFocused: Bool

    private func updateDrag(to point: CGPoint, in size: CGSize) {
        guard let dragOrigin else { return }
        let boundedPoint = CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))

        if let origin = selectionAtDragStart {
            let x = min(max(origin.minX + boundedPoint.x - dragOrigin.x, 0), max(0, size.width - origin.width))
            let y = min(max(origin.minY + boundedPoint.y - dragOrigin.y, 0), max(0, size.height - origin.height))
            selection = CGRect(origin: CGPoint(x: x, y: y), size: origin.size)
            return
        }

        selection = CGRect(
            x: min(dragOrigin.x, boundedPoint.x),
            y: min(dragOrigin.y, boundedPoint.y),
            width: abs(boundedPoint.x - dragOrigin.x),
            height: abs(boundedPoint.y - dragOrigin.y)
        )
    }

    private func textMarkup(at location: CGPoint, in size: CGSize) -> Markup? {
        return markups.last { markup in
            guard markup.tool == .text, let origin = markup.points.first else { return false }
            let fontSize = markup.fontSize > 0 ? markup.fontSize : max(16, size.width / 30)
            let rect = CGRect(x: origin.x * size.width - 9,
                              y: origin.y * size.height - 7,
                              width: max(fontSize, CGFloat(markup.label.count) * fontSize * 0.7) + 18,
                              height: fontSize * 1.5 + 14)
            return rect.contains(location)
        }
    }

    private func beginTextEntry(at location: CGPoint, in size: CGSize) {
        let point = CGPoint(x: min(max(location.x / max(size.width, 1), 0), 1),
                            y: min(max(location.y / max(size.height, 1), 0), 1))
        if let existing = textMarkup(at: location, in: size) {
            editingMarkupID = existing.id
            editingMarkupColor = existing.color
            selectedColor = existing.color
            selectedFontSize = existing.fontSize > 0 ? existing.fontSize : max(16, size.width / 30)
            textEntryPosition = existing.points.first
            annotationText = existing.label
        } else {
            editingMarkupID = nil
            editingMarkupColor = nil
            textEntryPosition = point
            annotationText = ""
        }
        DispatchQueue.main.async { textFieldFocused = true }
    }

    private func commitTextEntry() {
        if let editingMarkupID, let index = markups.firstIndex(where: { $0.id == editingMarkupID }) {
            if annotationText.isEmpty {
                markups.remove(at: index)
            } else {
                markups[index].label = annotationText
                if let editingMarkupColor, selectedColor != editingMarkupColor {
                    markups[index].color = selectedColor
                }
                markups[index].fontSize = selectedFontSize
            }
        } else if let textEntryPosition, !annotationText.isEmpty {
            markups.append(Markup(tool: .text, points: [textEntryPosition], label: annotationText,
                                  color: selectedColor, fontSize: selectedFontSize))
        }
        textEntryPosition = nil
        editingMarkupID = nil
        editingMarkupColor = nil
        annotationText = ""
        textFieldFocused = false
    }

    private func drawMarkups(in context: inout GraphicsContext, size: CGSize) {
        for markup in markups.filter({ $0.id != editingMarkupID }) + (draft.map { [$0] } ?? []) {
            guard let first = markup.points.first else { continue }
            let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
            var path = Path()
            path.move(to: start)
            if markup.tool == .pen {
                for point in markup.points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
            } else if markup.points.count > 1 {
                let end = CGPoint(x: markup.points[1].x * size.width, y: markup.points[1].y * size.height)
                if markup.tool == .rectangle {
                    path.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                        width: abs(start.x - end.x), height: abs(start.y - end.y)))
                } else if markup.tool == .arrow {
                    path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let headLength: CGFloat = 12
                    for offset: CGFloat in [-0.55, 0.55] {
                        path.move(to: end)
                        path.addLine(to: CGPoint(x: end.x - headLength * cos(angle + offset),
                                                 y: end.y - headLength * sin(angle + offset)))
                    }
                }
            }
            context.stroke(path, with: .color(markup.color),
                           style: StrokeStyle(lineWidth: max(2, size.width / 250), lineCap: .round, lineJoin: .round))
            if markup.tool == .text, !markup.label.isEmpty {
                let fontSize = markup.fontSize > 0 ? markup.fontSize : max(16, size.width / 30)
                context.draw(Text(markup.label).font(.system(size: fontSize, weight: .bold)).foregroundColor(markup.color),
                             at: start, anchor: .topLeading)
            }
        }
        if let textEntryPosition, !annotationText.isEmpty, !textFieldFocused {
            let start = CGPoint(x: textEntryPosition.x * size.width, y: textEntryPosition.y * size.height)
            context.draw(Text(annotationText).font(.system(size: selectedFontSize, weight: .bold)).foregroundColor(selectedColor),
                         at: start, anchor: .topLeading)
        }
    }

    private func renderedSelection(_ rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scaleX = CGFloat(cgImage.width) / max(image.size.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(image.size.height, 1)
        let pixelRect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                               width: rect.width * scaleX, height: rect.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        let base = NSImage(cgImage: cropped, size: rect.size)
        guard !markups.isEmpty else { return base }

        let renderer = ImageRenderer(content:
            ZStack {
                Image(nsImage: base).resizable().frame(width: rect.width, height: rect.height)
                Canvas { context, size in drawMarkups(in: &context, size: size) }
                    .frame(width: rect.width, height: rect.height)
            }
            .frame(width: rect.width, height: rect.height)
        )
        renderer.scale = max(1, CGFloat(cropped.width) / max(rect.width, 1))
        return renderer.nsImage ?? base
    }

    private func finish(_ action: SelectionAction, rect: CGRect) {
        if textEntryPosition != nil { commitTextEntry() }
        guard let rendered = renderedSelection(rect) else { return }
        onAction(rect, action, rendered)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)

                SelectionDragInput(
                    onStart: { point in
                        guard selectedTool == nil else { return }
                        if let selection, selection.contains(point) {
                            dragOrigin = point
                            selectionAtDragStart = selection
                            return
                        }
                        guard selection == nil else { return }
                        dragOrigin = point
                        selectionAtDragStart = nil
                        selection = CGRect(origin: point, size: .zero)
                    },
                    onMove: { updateDrag(to: $0, in: size) },
                    onEnd: { point in
                        guard selectedTool == nil else { return }
                        updateDrag(to: point, in: size)
                        let isCreatingSelection = selectionAtDragStart == nil
                        guard let rect = selection, rect.width >= 2, rect.height >= 2 else {
                            if isCreatingSelection { selection = nil }
                            dragOrigin = nil
                            selectionAtDragStart = nil
                            return
                        }
                        dragOrigin = nil
                        selectionAtDragStart = nil
                        if recognize && isCreatingSelection { onSelection(rect) }
                    }
                )
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(selectedTool == nil)

                Canvas { context, canvasSize in
                    guard let selection else { return }
                    var mask = Path()
                    mask.addRect(CGRect(origin: .zero, size: canvasSize))
                    mask.addRect(selection)
                    context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))

                    let lineWidth: CGFloat = 1.5
                    let borderRect = selection.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    guard borderRect.width > 0, borderRect.height > 0 else { return }
                    context.stroke(Path(borderRect), with: .color(.cyan), lineWidth: lineWidth)
                }
                .allowsHitTesting(false)

                if let selection {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, canvasSize in drawMarkups(in: &context, size: canvasSize) }
                        if selectedTool != nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: selectedTool == .pen ? 0 : (selectedTool == .text ? 3 : 4))
                                    .onChanged { value in
                                        guard let selectedTool else { return }
                                        if selectedTool == .text {
                                            if movingMarkupID == nil,
                                               let markup = textMarkup(at: value.startLocation, in: selection.size),
                                               let origin = markup.points.first {
                                                movingMarkupID = markup.id
                                                movingMarkupOrigin = origin
                                            }
                                            guard let movingMarkupID, let movingMarkupOrigin,
                                                  let index = markups.firstIndex(where: { $0.id == movingMarkupID }) else { return }
                                            markups[index].points[0] = CGPoint(
                                                x: min(max(movingMarkupOrigin.x + value.translation.width / max(selection.width, 1), 0), 1),
                                                y: min(max(movingMarkupOrigin.y + value.translation.height / max(selection.height, 1), 0), 1)
                                            )
                                            return
                                        }

                                        let start = CGPoint(x: value.startLocation.x / max(selection.width, 1),
                                                            y: value.startLocation.y / max(selection.height, 1))
                                        let current = CGPoint(x: value.location.x / max(selection.width, 1),
                                                              y: value.location.y / max(selection.height, 1))
                                        if draft == nil { draft = Markup(tool: selectedTool, points: [start], color: selectedColor) }
                                        if selectedTool == .pen { draft?.points.append(current) }
                                        else { draft?.points = [start, current] }
                                    }
                                    .onEnded { value in
                                        if selectedTool == .text {
                                            movingMarkupID = nil
                                            movingMarkupOrigin = nil
                                        } else if let draft {
                                            markups.append(draft)
                                        }
                                        draft = nil
                                    })
                                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                                        guard selectedTool == .text else { return }
                                        beginTextEntry(at: value.location, in: selection.size)
                                    })
                        }
                        if let entryPosition = textEntryPosition {
                            let fieldWidth = max(40, min(240, selection.width - 8))
                            let x = min(max(entryPosition.x * selection.width, 4), max(4, selection.width - fieldWidth - 4))
                            let y = min(max(entryPosition.y * selection.height, 4), max(4, selection.height - 36))
                            TextField("输入文字", text: $annotationText)
                                .textFieldStyle(.plain)
                                .font(.system(size: selectedFontSize, weight: .bold))
                                .frame(width: fieldWidth)
                                .foregroundStyle(selectedColor)
                                .focused($textFieldFocused)
                                .background(Color.clear)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(selectedColor.opacity(0.9), lineWidth: 1)
                                }
                                .onSubmit(commitTextEntry)
                                .position(x: x + fieldWidth / 2, y: y + 18)
                        }
                    }
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .allowsHitTesting(selectedTool != nil || textEntryPosition != nil)
                }

                if let selection, dragOrigin == nil {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            ForEach(MarkupTool.allCases) { item in
                                Button {
                                    if textEntryPosition != nil { commitTextEntry() }
                                    selectedTool = selectedTool == item ? nil : item
                                } label: {
                                    toolbarIcon(item.symbol)
                                        .foregroundStyle(.white)
                                        .background {
                                            if selectedTool == item {
                                                RoundedRectangle(cornerRadius: 7)
                                                    .fill(Color.accentColor.opacity(0.92))
                                            }
                                        }
                                        .overlay {
                                            if selectedTool == item {
                                                RoundedRectangle(cornerRadius: 7)
                                                    .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                                            }
                                        }
                                }
                                .help(item.rawValue)
                            }
                            if selectedTool == .text {
                                FontSizePicker(selection: $selectedFontSize)
                            }
                            Button { if !markups.isEmpty { markups.removeLast() } } label: { toolbarIcon("arrow.uturn.backward") }
                                .help("撤销标注")
                            Button(action: onCancel) { toolbarIcon("xmark") }
                                .help("取消截图")
                                .keyboardShortcut(.cancelAction)
                            Rectangle().fill(.white.opacity(0.45)).frame(width: 1, height: 20)
                            Button { finish(.pin, rect: selection) } label: { toolbarIcon("pin.fill") }
                                .help("钉住图片")
                            Button { finish(.copy, rect: selection) } label: { toolbarIcon("doc.on.doc") }
                                .help("复制图片并关闭")
                            Button { finish(.save, rect: selection) } label: { toolbarIcon("square.and.arrow.down") }
                                .help("保存图片")
                        }
                        CompactColorPalette(selection: $selectedColor)
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .position(
                        x: min(max(selection.midX, 270), max(270, size.width - 270)),
                        y: selection.maxY + 60 + 44 < size.height
                            ? selection.maxY + 60
                            : max(44, selection.minY - 60)
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .onExitCommand(perform: onCancel)
        .onChange(of: textFieldFocused) { _, isFocused in
            if !isFocused, textEntryPosition != nil { commitTextEntry() }
        }
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

struct ContentView: View {
    @Environment(PiOcrModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 42)).foregroundStyle(.tint)
            Text("PiOcr").font(.title2.bold())
            Text("从菜单栏开始区域截图、标注和 OCR 识别。")
                .foregroundStyle(.secondary)
            Button("区域截图识别并复制文字") { model.startCapture(recognize: true) }
                .keyboardShortcut(.return)
        }
        .frame(minWidth: 360, minHeight: 220)
        .padding()
    }
}

private enum MarkupTool: String, CaseIterable, Identifiable {
    case pen = "画笔", arrow = "箭头", rectangle = "矩形", text = "文字"
    var id: String { rawValue }
    var symbol: String { switch self { case .pen: "pencil.tip"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .text: "textformat" } }
}

private struct Markup: Identifiable {
    let id = UUID()
    let tool: MarkupTool
    var points: [CGPoint]
    var label: String = ""
    var color: Color = .red
    var fontSize: CGFloat = 0
}

private struct FontSizePicker: View {
    @Binding var selection: CGFloat
    private let sizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64]

    var body: some View {
        Picker("字号", selection: $selection) {
            ForEach(sizes, id: \.self) { size in
                Text("\(Int(size))").tag(size)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 54)
        .help("文字字号")
    }
}

private struct ScreenshotEditorView: View {
    @Bindable var model: PiOcrModel
    let image: NSImage
    let selectionSize: CGSize
    let panelID: UUID
    @State private var tool: MarkupTool = .pen
    @State private var selectedColor: Color = .red
    @State private var selectedFontSize: CGFloat = 24
    @State private var markups: [Markup] = []
    @State private var draft: Markup?
    @State private var annotationText = ""
    @State private var textEntryPosition: CGPoint?
    @State private var editingMarkupID: UUID?
    @State private var editingMarkupColor: Color?
    @State private var movingMarkupID: UUID?
    @State private var movingMarkupOrigin: CGPoint?
    @State private var selectedTextMarkupID: UUID?
    @FocusState private var textFieldFocused: Bool

    private var compositedImage: NSImage {
        // Keep the native screenshot representation when there is nothing to
        // composite. ImageRenderer at 1x would otherwise discard Retina pixels.
        guard !markups.isEmpty || draft != nil else { return image }
        let size = NSSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
        let renderer = ImageRenderer(content:
            ZStack {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                Canvas { context, canvasSize in drawMarkups(in: &context, size: canvasSize, showsSelection: false) }
            }
            .frame(width: size.width, height: size.height)
        )
        let pixelWidth = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
        renderer.scale = max(1, CGFloat(pixelWidth ?? Int(size.width)) / size.width)
        return renderer.nsImage ?? image
    }

    private func drawMarkups(in context: inout GraphicsContext, size: CGSize, showsSelection: Bool = true) {
        for markup in markups.filter({ $0.id != editingMarkupID }) + (draft.map { [$0] } ?? []) {
            guard let first = markup.points.first else { continue }
            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(x: value.x * size.width, y: value.y * size.height)
            }
            var path = Path()
            path.move(to: point(first))
            if markup.tool == .pen {
                for value in markup.points.dropFirst() { path.addLine(to: point(value)) }
            } else if markup.points.count > 1 {
                let end = point(markup.points[1])
                if markup.tool == .rectangle {
                    path.addRect(CGRect(x: min(first.x, markup.points[1].x) * size.width,
                                        y: min(first.y, markup.points[1].y) * size.height,
                                        width: abs(first.x - markup.points[1].x) * size.width,
                                        height: abs(first.y - markup.points[1].y) * size.height))
                } else {
                    path.addLine(to: end)
                    if markup.tool == .arrow { path.addLines([end, CGPoint(x: end.x - 10, y: end.y - 4), end]) }
                }
            }
            context.stroke(path, with: .color(markup.color), style: StrokeStyle(lineWidth: max(2, size.width / 250), lineCap: .round, lineJoin: .round))
            if markup.tool == .text, !markup.label.isEmpty {
                let fontSize = markup.fontSize > 0 ? markup.fontSize : max(16, size.width / 30)
                let textRect = CGRect(x: first.x * size.width, y: first.y * size.height,
                                      width: max(fontSize, CGFloat(markup.label.count) * fontSize * 0.7),
                                      height: fontSize * 1.5)
                if showsSelection, tool == .text, selectedTextMarkupID == markup.id {
                    context.stroke(Path(roundedRect: textRect.insetBy(dx: -7, dy: -5), cornerRadius: 5), with: .color(.white), lineWidth: 1)
                    context.stroke(Path(roundedRect: textRect.insetBy(dx: -8, dy: -6), cornerRadius: 5), with: .color(.blue), lineWidth: 1)
                }
                context.draw(Text(markup.label).font(.system(size: fontSize, weight: .bold)).foregroundColor(markup.color), at: point(first), anchor: .topLeading)
            }
        }
        if let textEntryPosition, !annotationText.isEmpty, !textFieldFocused {
            let previewPoint = CGPoint(x: textEntryPosition.x * size.width, y: textEntryPosition.y * size.height)
            context.draw(Text(annotationText).font(.system(size: selectedFontSize, weight: .bold)).foregroundColor(selectedColor),
                         at: previewPoint, anchor: .topLeading)
        }
    }

    private func textMarkup(at location: CGPoint) -> Markup? {
        return markups.last { markup in
            guard markup.tool == .text, let origin = markup.points.first else { return false }
            let fontSize = markup.fontSize > 0 ? markup.fontSize : max(16, selectionSize.width / 30)
            let rect = CGRect(x: origin.x * selectionSize.width - 9,
                              y: origin.y * selectionSize.height - 7,
                              width: max(fontSize, CGFloat(markup.label.count) * fontSize * 0.7) + 18,
                              height: fontSize * 1.5 + 14)
            return rect.contains(location)
        }
    }

    private func beginTextEntry(at location: CGPoint) {
        if textEntryPosition != nil { commitTextEntry() }
        let point = CGPoint(
            x: min(max(location.x / max(selectionSize.width, 1), 0), 1),
            y: min(max(location.y / max(selectionSize.height, 1), 0), 1)
        )
        let existing = textMarkup(at: location)

        if let existing {
            editingMarkupID = existing.id
            editingMarkupColor = existing.color
            selectedColor = existing.color
            selectedFontSize = existing.fontSize > 0 ? existing.fontSize : max(16, selectionSize.width / 30)
            selectedTextMarkupID = existing.id
            textEntryPosition = existing.points.first
            annotationText = existing.label
        } else {
            editingMarkupID = nil
            editingMarkupColor = nil
            selectedTextMarkupID = nil
            textEntryPosition = point
            annotationText = ""
        }
        // The TextField is created by the next SwiftUI update. Request focus
        // after that update so the initial focus request is not lost.
        DispatchQueue.main.async {
            textFieldFocused = true
        }
    }

    private func commitTextEntry() {
        if let editingMarkupID,
           let index = markups.firstIndex(where: { $0.id == editingMarkupID }) {
            if annotationText.isEmpty {
                markups.remove(at: index)
            } else {
                markups[index].label = annotationText
                if let editingMarkupColor, selectedColor != editingMarkupColor {
                    markups[index].color = selectedColor
                }
                markups[index].fontSize = selectedFontSize
            }
        } else if let textEntryPosition, !annotationText.isEmpty {
            let markup = Markup(tool: .text, points: [textEntryPosition], label: annotationText,
                                color: selectedColor, fontSize: selectedFontSize)
            markups.append(markup)
            selectedTextMarkupID = markup.id
        }
        dismissTextEntry()
    }

    private func dismissTextEntry() {
        textEntryPosition = nil
        editingMarkupID = nil
        editingMarkupColor = nil
        annotationText = ""
        textFieldFocused = false
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: selectionSize.width, height: selectionSize.height)
                    .overlay(Rectangle().stroke(Color.cyan, lineWidth: 2).allowsHitTesting(false))
                Canvas { context, size in drawMarkups(in: &context, size: size) }
                    .frame(width: selectionSize.width, height: selectionSize.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: tool == .pen ? 0 : (tool == .text ? 3 : 4))
                        .onChanged { value in
                            if tool == .text {
                                if movingMarkupID == nil,
                                   let markup = textMarkup(at: value.startLocation),
                                   let origin = markup.points.first {
                                    movingMarkupID = markup.id
                                    movingMarkupOrigin = origin
                                    selectedTextMarkupID = markup.id
                                }
                                guard let movingMarkupID,
                                      let movingMarkupOrigin,
                                      let index = markups.firstIndex(where: { $0.id == movingMarkupID }) else { return }
                                markups[index].points[0] = CGPoint(
                                    x: min(max(movingMarkupOrigin.x + value.translation.width / max(selectionSize.width, 1), 0), 1),
                                    y: min(max(movingMarkupOrigin.y + value.translation.height / max(selectionSize.height, 1), 0), 1)
                                )
                                return
                            }
                            let start = CGPoint(x: value.startLocation.x / max(selectionSize.width, 1), y: value.startLocation.y / max(selectionSize.height, 1))
                            let current = CGPoint(x: value.location.x / max(selectionSize.width, 1), y: value.location.y / max(selectionSize.height, 1))
                            if draft == nil { draft = Markup(tool: tool, points: [start], color: selectedColor) }
                            if tool == .pen { draft?.points.append(current) }
                            else { draft?.points = [start, current] }
                        }
                        .onEnded { value in
                            if tool == .text {
                                movingMarkupID = nil
                                movingMarkupOrigin = nil
                            } else if let draft {
                                markups.append(draft)
                            }
                            draft = nil
                        })
                        .simultaneousGesture(SpatialTapGesture().onEnded { value in
                            guard tool == .text else { return }
                            beginTextEntry(at: value.location)
                        })
                if let textEntryPosition {
                    let fieldWidth = max(40, min(240, selectionSize.width - 8))
                    let x = min(max(textEntryPosition.x * selectionSize.width, 4), max(4, selectionSize.width - fieldWidth - 4))
                    let y = min(max(textEntryPosition.y * selectionSize.height, 4), max(4, selectionSize.height - 38))
                    TextField("输入文字", text: $annotationText)
                        .textFieldStyle(.plain)
                        .font(.system(size: selectedFontSize, weight: .bold))
                        .frame(width: fieldWidth)
                        .foregroundStyle(selectedColor)
                        .focused($textFieldFocused)
                        .background(Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(selectedColor.opacity(0.9), lineWidth: 1)
                        }
                        .onAppear {
                            DispatchQueue.main.async {
                                textFieldFocused = true
                            }
                        }
                        .onSubmit(commitTextEntry)
                        .position(x: x + fieldWidth / 2, y: y + 18)
                }
            }
            .frame(width: selectionSize.width, height: selectionSize.height)
            .clipped()
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    ForEach(MarkupTool.allCases) { item in
                        Button {
                            if textEntryPosition != nil { commitTextEntry() }
                            tool = item
                            if item != .text { selectedTextMarkupID = nil }
                        } label: {
                            Image(systemName: item.symbol).frame(width: 27, height: 25)
                        }.help(item.rawValue).tint(tool == item ? .accentColor : .secondary)
                    }
                    if tool == .text {
                        FontSizePicker(selection: $selectedFontSize)
                    }
                    Divider().frame(height: 20)
                    Button { if !markups.isEmpty { markups.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销")
                    Button {
                        if model.copyImage(compositedImage) { model.closeEditor(panelID) }
                    } label: { Image(systemName: "doc.on.doc") }.help("复制截图并关闭")
                    Button {
                        model.saveImage(compositedImage, from: panelID)
                    } label: { Image(systemName: "square.and.arrow.down") }.help("保存图片并关闭")
                    Button { model.closeEditor(panelID) } label: { Image(systemName: "xmark") }.help("关闭截图")
                    Button { model.pinEditor(panelID, image: compositedImage) } label: {
                        Image(systemName: "pin.fill")
                    }.help("钉住图片并退出编辑")
                    Spacer(minLength: 2)
                    Button { model.recognizeText() } label: {
                        if model.isRecognizing { ProgressView().controlSize(.small) } else { Image(systemName: "text.viewfinder").frame(width: 27, height: 25) }
                    }.disabled(model.isRecognizing)
                }
                CompactColorPalette(selection: $selectedColor)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.clear)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(Color.clear)
        .onExitCommand { model.closeEditor(panelID) }
        .onChange(of: textFieldFocused) { _, isFocused in
            if !isFocused, textEntryPosition != nil { commitTextEntry() }
        }
    }
}

private struct CompactColorPalette: View {
    @Binding var selection: Color
    private let colors: [Color] = [
        Color(red: 0.10, green: 0.88, blue: 0.22), .black, .gray, .brown,
        .pink, .purple, .red, .orange, .yellow, .green, .mint, .cyan, .blue, .indigo,
        .teal, .white,
        Color(red: 0.72, green: 1.0, blue: 0.72), Color(red: 0.92, green: 0.92, blue: 0.92),
        Color(red: 1.0, green: 0.78, blue: 0.82), Color(red: 0.83, green: 0.75, blue: 0.95),
        Color(red: 1.0, green: 0.78, blue: 0.68), Color(red: 1.0, green: 0.88, blue: 0.55),
        Color(red: 0.98, green: 0.96, blue: 0.70), Color(red: 0.74, green: 0.91, blue: 0.78),
        Color(red: 0.70, green: 0.88, blue: 0.94), Color(red: 0.72, green: 0.82, blue: 1.0),
        Color(red: 0.83, green: 0.78, blue: 0.91), Color(red: 0.96, green: 0.80, blue: 0.73)
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 2), count: 14), spacing: 2) {
            ForEach(colors.indices, id: \.self) { index in
                let color = colors[index]
                Button { selection = color } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.9), lineWidth: 1))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.8), lineWidth: selection == color ? 2 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("标注颜色")
            }
        }
        .fixedSize()
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Color.clear)
    }
}

private struct PinnedScreenshotView: View {
    let image: NSImage
    let panelID: UUID
    let model: PiOcrModel
    let displaySize: CGSize
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var magnificationStart: CGFloat?

    private func applyMagnification(_ magnification: CGFloat) {
        if magnificationStart == nil { magnificationStart = scale }
        scale = min(max((magnificationStart ?? scale) * magnification, 0.2), 5)
        model.resizePinnedEditor(
            panelID,
            to: CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        )
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: displaySize.width * scale, height: displaySize.height * scale)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: .blue.opacity(0.58), radius: 12, x: 0, y: 0)
            .background(Color.clear)
            .onTapGesture(count: 2, perform: onClose)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in applyMagnification(value.magnification) }
                    .onEnded { value in
                        applyMagnification(value.magnification)
                        magnificationStart = nil
                    }
            )
            .contextMenu {
                Button("关闭截图", systemImage: "xmark", action: onClose)
            }
            .background {
                ScrollWheelZoomMonitor(panelID: panelID, model: model, scale: $scale, displaySize: displaySize)
                    .frame(width: 0, height: 0)
            }
    }
}

private struct ScrollWheelZoomMonitor: NSViewRepresentable {
    let panelID: UUID
    let model: PiOcrModel
    @Binding var scale: CGFloat
    let displaySize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(panelID: panelID, model: model, scale: $scale, displaySize: displaySize)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scale = $scale
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        let panelID: UUID
        let model: PiOcrModel
        var scale: Binding<CGFloat>
        let displaySize: CGSize
        private var eventMonitor: Any?

        init(panelID: UUID, model: PiOcrModel, scale: Binding<CGFloat>, displaySize: CGSize) {
            self.panelID = panelID
            self.model = model
            self.scale = scale
            self.displaySize = displaySize
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let windowNumber = event.window?.windowNumber,
                      self.model.isEditorWindow(self.panelID, windowNumber: windowNumber) else { return event }

                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 12
                guard delta != 0 else { return event }
                let factor = CGFloat(pow(1.0025, Double(delta)))
                let newScale = min(max(self.scale.wrappedValue * factor, 0.2), 5)
                self.scale.wrappedValue = newScale
                self.model.resizePinnedEditor(
                    self.panelID,
                    to: CGSize(width: self.displaySize.width * newScale, height: self.displaySize.height * newScale),
                    anchoredAt: event.locationInWindow
                )
                return nil
            }
        }

        func stop() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }
}

#Preview {
    ContentView().environment(PiOcrModel())
}
