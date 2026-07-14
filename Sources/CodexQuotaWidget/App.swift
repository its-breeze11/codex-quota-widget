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

final class PanelPresentation: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Bump the autosave key so the compact default takes effect once before
    // subsequent manual resizing is remembered.
    private static let panelFrameName = "CodexQuotaWidgetPanel-v12"
    private static let collapsedPanelSize = NSSize(width: 360, height: 350)
    private static let expandedPanelSize = NSSize(width: 720, height: 350)
    // This dashboard is designed as a two-column surface. Keep enough room for
    // the history chart and its footer instead of falling back to a vertically
    // scrolling layout or allowing the app footer to overlap card content.
    private static let collapsedMinimumSize = NSSize(width: 360, height: 350)
    private static let expandedMinimumSize = NSSize(width: 720, height: 350)

    private let viewModel = DashboardViewModel()
    private let presentation = PanelPresentation()
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep a Dock presence so the yellow traffic light can use the normal
        // macOS miniaturize behavior and remain discoverable after minimizing.
        NSApp.setActivationPolicy(.regular)
        configurePanel()
        configureStatusItem()
        observeViewModel()
        viewModel.start()
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.saveFrame(usingName: Self.panelFrameName)
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
            contentRect: NSRect(origin: .zero, size: Self.collapsedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = Self.collapsedMinimumSize
        panel.contentMinSize = Self.collapsedMinimumSize
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: DashboardView(
                viewModel: viewModel,
                presentation: presentation,
                togglePresentation: { [weak self] in self?.togglePresentation() }
            )
        )
        panel.setFrameAutosaveName(Self.panelFrameName)

        if !panel.setFrameUsingName(Self.panelFrameName),
           let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 20,
                y: visible.maxY - panel.frame.height - 20
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
    }

    private func togglePresentation() {
        guard let panel else { return }
        let expands = !presentation.isExpanded
        let targetSize = expands ? Self.expandedPanelSize : Self.collapsedPanelSize
        let targetMinimumSize = expands ? Self.expandedMinimumSize : Self.collapsedMinimumSize

        panel.minSize = targetMinimumSize
        panel.contentMinSize = targetMinimumSize
        presentation.isExpanded = expands

        var frame = panel.frame
        frame.size = targetSize

        // Animating both NSPanel's frame and SwiftUI's conditional right column
        // causes a visible second layout bounce while collapsing. Apply one
        // atomic resize instead.
        panel.setFrame(frame, display: true, animate: false)
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
