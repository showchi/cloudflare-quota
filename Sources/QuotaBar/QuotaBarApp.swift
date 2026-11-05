import AppKit
import QuotaCore
import SwiftUI

enum AppActivation {
    /// Settings windows need a regular activation policy or text fields accept
    /// paste and ignore keystrokes. The menu bar itself stays an accessory item.
    @MainActor
    static func becomeRegular() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func restoreAccessoryIfNoInputWindows() {
        let needsKeyboard = NSApplication.shared.windows.contains {
            $0.isVisible && $0.canBecomeKey
                && !$0.styleMask.contains(.nonactivatingPanel)
        }
        if !needsKeyboard {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(L10n.text(.quitApp, language: appDelegate.model.stored.language)) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hosting: NSHostingView<MenuPanel>?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private let tracePanelEvents = ProcessInfo.processInfo.environment["QUOTA_DEBUG_EVENTS"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearanceController.apply(model.stored.appearance)
        NSApplication.shared.setActivationPolicy(.accessory)
        installStatusItem()
        model.onMenuTitleChange = { [weak self] in
            self?.updateTitle()
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.tracePanelEvent("global-mouse-down", event: event)
            self?.panel?.orderOut(nil)
            self?.tracePanelEvent("global-mouse-down-finished", event: event)
        }
        if tracePanelEvents {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
                self?.tracePanelEvent("local-mouse", event: event)
                return event
            }
        }
        model.start()
        if !model.stored.showMenuBar {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = menuImage() {
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateTitle()
    }

    private func menuImage() -> NSImage? {
        guard let image = AppResources.bundle()?.image(forResource: "MenuTemplate") else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func updateTitle() {
        statusItem?.isVisible = model.stored.showMenuBar
        statusItem?.button?.title = model.menuTitle
        if panel?.isVisible == true { updatePanelLayout() }
    }

    @objc private func togglePanel(_ sender: NSButton) {
        tracePanelEvent("status-action", event: NSApplication.shared.currentEvent)
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            tracePanelEvent("status-action-hidden")
            return
        }
        showPanel()
    }

    private func showPanel() {
        updatePanelLayout()
        panel?.orderFrontRegardless()
        tracePanelEvent("panel-shown")
    }

    /// Refresh content and geometry without changing visibility or window ordering.
    private func updatePanelLayout() {
        let button = statusItem?.button
        let screen = button?.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let root = MenuPanel(model: model, onManage: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.showSettings()
        }, maximumHeight: max(1, visibleFrame.height - 8))
        let view = hosting ?? NSHostingView(rootView: root)
        view.rootView = root
        hosting = view
        view.frame.size = view.fittingSize
        let size = view.fittingSize
        let window = panel ?? {
            let created = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.level = .statusBar
            created.isFloatingPanel = true
            created.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.hidesOnDeactivate = false
            panel = created
            return created
        }()
        window.contentView = view
        window.setContentSize(size)
        let anchor = button.flatMap { button in
            button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        } ?? NSRect(x: visibleFrame.midX, y: visibleFrame.maxY, width: 0, height: 0)
        window.setFrame(PanelGeometry.frame(for: size, anchoredTo: anchor, within: visibleFrame), display: true)
        tracePanelEvent("panel-layout-updated")
    }

    private func tracePanelEvent(_ source: String, event: NSEvent? = nil) {
        guard tracePanelEvents else { return }
        NSLog("QuotaPanel source=%@ event=%@ eventTime=%.6f window=%ld mouse=%@ visible=%@", source,
              event.map { String(describing: $0.type) } ?? "-", event?.timestamp ?? 0,
              event?.windowNumber ?? -1, NSStringFromPoint(NSEvent.mouseLocation),
              String(panel?.isVisible == true))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "quota-settings" else { return }
        model.draft = nil
        Task { @MainActor in
            AppActivation.restoreAccessoryIfNoInputWindows()
        }
    }

    func windowDidEndSheet(_ notification: Notification) {
        AppActivation.restoreAccessoryIfNoInputWindows()
    }

    private func showSettings() {
        AppActivation.becomeRegular()
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "quota-settings" }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("quota-settings")
        window.title = "Cloudflare Quota"
        window.contentView = NSHostingView(rootView: MainWindow(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}
