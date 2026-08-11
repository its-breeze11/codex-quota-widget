import AppKit
import Combine
import SwiftUI

@main
struct CodexQuotaWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PanelMode {
    case ball
    case panel
    case progress
}

final class PanelPresentation: ObservableObject {
    @Published var mode: PanelMode = .ball
    @Published var isChartVisible = true
    @Published private(set) var panelHeight: CGFloat = 350

    var isExpanded: Bool { mode == .panel }

    func updatePanelHeight(_ height: CGFloat) {
        panelHeight = height
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let floatingBallSize = NSSize(width: 60, height: 60)
    private static let expandedPanelSize = NSSize(width: 720, height: 350)
    private static let expandedMinimumSize = NSSize(width: 720, height: 350)
    private static let collapsedPanelSize = NSSize(width: 360, height: 350)
    private static let collapsedMinimumSize = NSSize(width: 320, height: 350)
    private static let progressBarSize = NSSize(width: 640, height: 16)
    private static let progressBarMinSize = NSSize(width: 320, height: 16)
    private static let progressBarMaxSize = NSSize(width: 2000, height: 16)

    private let viewModel = DashboardViewModel()
    private let presentation = PanelPresentation()
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保留 Dock 图标，让黄色窗口按钮使用 macOS 默认的最小化行为，
        // 最小化后仍然可以方便地找回应用。
        NSApp.setActivationPolicy(.regular)
        configurePanel()
        configureStatusItem()
        observeViewModel()
        viewModel.start()
        showPanel()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPanel()
        return true
    }

    private func configurePanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.floatingBallSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = Self.floatingBallSize
        panel.contentMinSize = Self.floatingBallSize
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 悬浮球由自身手势负责拖动。如果同时允许 NSPanel 通过窗口背景移动，
        // 拖动时会发生位置更新竞争，导致画面频闪。
        // 展开面板则使用 AppKit 原生的窗口背景拖动。
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(
            rootView: DashboardView(
                viewModel: viewModel,
                presentation: presentation,
                togglePresentation: { [weak self] in self?.togglePresentation() },
                toggleChart: { [weak self] in self?.toggleChart() },
                toggleProgressBar: { [weak self] in self?.toggleProgressBar() }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.delegate = self

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 20,
                y: visible.maxY - panel.frame.height - 20
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        presentation.updatePanelHeight(panel.frame.height)
    }

    private func togglePresentation() {
        guard let panel, presentation.mode != .progress else { return }
        let expands = presentation.mode == .ball
        let targetSize: NSSize
        let targetMinimumSize: NSSize
        if expands {
            if presentation.isChartVisible {
                targetSize = Self.expandedPanelSize
                targetMinimumSize = Self.expandedMinimumSize
            } else {
                targetSize = Self.collapsedPanelSize
                targetMinimumSize = Self.collapsedMinimumSize
            }
        } else {
            targetSize = Self.floatingBallSize
            targetMinimumSize = Self.floatingBallSize
        }

        let currentFrame = panel.frame
        let frame: NSRect
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if expands {
            // 展开是收起的逆操作：让面板减号按钮中心与悬浮球中心对齐。
            // 减号按钮距面板左边缘 41pt、距顶部 23pt。
            let ballCenter = NSPoint(
                x: currentFrame.midX,
                y: currentFrame.midY
            )
            let desiredOrigin = NSPoint(
                x: ballCenter.x - 41,
                y: ballCenter.y + 23 - targetSize.height
            )
            let maxX = max(visibleFrame.minX, visibleFrame.maxX - targetSize.width)
            let maxY = max(visibleFrame.minY, visibleFrame.maxY - targetSize.height)
            frame = NSRect(
                x: min(max(desiredOrigin.x, visibleFrame.minX), maxX),
                y: min(max(desiredOrigin.y, visibleFrame.minY), maxY),
                width: targetSize.width,
                height: targetSize.height
            )
        } else {
            // 黄色减号距离面板左边 41pt、距离顶部 23pt，
            // 让悬浮球中心对齐到减号按钮中心。
            let minusCenter = NSPoint(
                x: currentFrame.minX + 41,
                y: currentFrame.maxY - 23
            )
            frame = NSRect(
                x: minusCenter.x - targetSize.width / 2,
                y: minusCenter.y - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            )
        }

        panel.minSize = targetMinimumSize
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        panel.contentMinSize = targetMinimumSize
        panel.hasShadow = expands
        panel.isMovableByWindowBackground = expands
        presentation.mode = expands ? .panel : .ball

        // 一次性调整窗口尺寸，让 SwiftUI 和 NSPanel 同步切换状态。
        panel.setFrame(frame, display: true, animate: false)
        presentation.updatePanelHeight(frame.height)
    }

    private func toggleChart() {
        guard let panel, presentation.isExpanded else { return }
        let showsChart = !presentation.isChartVisible
        let targetWidth = showsChart
            ? Self.expandedPanelSize.width
            : Self.collapsedPanelSize.width
        let minWidth = showsChart
            ? Self.expandedMinimumSize.width
            : Self.collapsedMinimumSize.width

        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var frame = panel.frame
        if showsChart {
            // 向右扩展；若超出屏幕右边界则向左收回。
            frame.size.width = targetWidth
            if frame.maxX > visibleFrame.maxX {
                frame.origin.x = visibleFrame.maxX - targetWidth
            }
        } else {
            // 从右侧收起，保持左边缘不动。
            frame.size.width = targetWidth
        }
        frame.origin.x = max(frame.origin.x, visibleFrame.minX)

        panel.minSize = NSSize(width: minWidth, height: panel.minSize.height)
        panel.contentMinSize = NSSize(width: minWidth, height: panel.contentMinSize.height)
        presentation.isChartVisible = showsChart
        panel.setFrame(frame, display: true, animate: true)
        presentation.updatePanelHeight(frame.height)
    }

    private func toggleProgressBar() {
        guard let panel else { return }
        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if presentation.mode == .panel {
            // 页面态 → 进度态：进度条在面板上方，水平居中
            let targetSize = Self.progressBarSize
            let currentFrame = panel.frame
            let desiredOrigin = NSPoint(
                x: currentFrame.midX - targetSize.width / 2,
                y: currentFrame.maxY + 8
            )
            let maxX = max(visibleFrame.minX, visibleFrame.maxX - targetSize.width)
            let frame = NSRect(
                x: min(max(desiredOrigin.x, visibleFrame.minX), maxX),
                y: min(desiredOrigin.y, visibleFrame.maxY - targetSize.height),
                width: targetSize.width,
                height: targetSize.height
            )
            panel.minSize = Self.progressBarMinSize
            panel.maxSize = Self.progressBarMaxSize
            panel.contentMinSize = Self.progressBarMinSize
            panel.hasShadow = true
            panel.isMovableByWindowBackground = false
            presentation.mode = .progress
            panel.setFrame(frame, display: true, animate: false)
            presentation.updatePanelHeight(frame.height)
        } else if presentation.mode == .progress {
            // 进度态 → 页面态：面板在进度条下方，水平居中
            let targetSize = presentation.isChartVisible
                ? Self.expandedPanelSize
                : Self.collapsedPanelSize
            let targetMinSize = presentation.isChartVisible
                ? Self.expandedMinimumSize
                : Self.collapsedMinimumSize
            let currentFrame = panel.frame
            let desiredOrigin = NSPoint(
                x: currentFrame.midX - targetSize.width / 2,
                y: currentFrame.minY - 8 - targetSize.height
            )
            let maxX = max(visibleFrame.minX, visibleFrame.maxX - targetSize.width)
            let maxY = max(visibleFrame.minY, visibleFrame.maxY - targetSize.height)
            let frame = NSRect(
                x: min(max(desiredOrigin.x, visibleFrame.minX), maxX),
                y: min(max(desiredOrigin.y, visibleFrame.minY), maxY),
                width: targetSize.width,
                height: targetSize.height
            )
            panel.minSize = targetMinSize
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            panel.contentMinSize = targetMinSize
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            presentation.mode = .panel
            panel.setFrame(frame, display: true, animate: false)
            presentation.updatePanelHeight(frame.height)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? FloatingPanel else { return }
        presentation.updatePanelHeight(panel.frame.height)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = viewModel.statusTitle
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Codex 用量")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func observeViewModel() {
        viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem?.button?.title = self.viewModel.statusTitle
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if panel?.isVisible == true, panel?.isMiniaturized == false {
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    @objc private func refresh() {
        viewModel.refresh()
    }

    @objc private func showPanel() {
        guard let panel else { return }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示悬浮窗", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
}
