import AppKit
import SwiftUI

private func trace(_ text: String) {
    guard ProcessInfo.processInfo.environment["QUIK_TRACE"] == "1" else { return }
    let path = "/tmp/quik-trace.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
        try? handle.close()
    } else {
        try? (text + "\n").write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
    }
}

final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let store = QuikStore()
    private let chrome = PanelChrome()
    private let engine = MonitorEngine()
    private var hud: HUDController?
    private var lastTitle = ""
    private var lastAppliedSignature = ""
    private var restoreHUDAfterPanel = false
    private var suppressHUDRestore = false
    private var showingAgentInstall = ProcessInfo.processInfo.environment["QUIK_PREVIEW_AGENT"] != nil
    private var panelWindow: NSPanel?
    private var panelHost: NSHostingView<PanelView>?
    private var panelPlacement: PanelPlacement = .centered
    private var panelDragMonitor: Any?
    private var panelDragPoint: NSPoint?

    /// The panel either hangs off the floating window, sits under the menu bar
    /// item, or floats alone in the middle. Only the first case is a pair.
    private enum PanelPlacement {
        case attached(edge: PanelArrow.Edge)
        case below(NSRect)
        case centered
    }
    private let dockIcon = DockIconController()

    init(preview: String? = nil) {
        trace("init entered")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        guard let button = item.button else {
            trace("init: button nil")
            return
        }
        trace("init: button ok")
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.attributedTitle = NSAttributedString(
            string: " Q",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )

        engine.onUpdate = { [weak self] assessment, history in
            guard let self else { return }
            let advanced = QuikStore.advancedMode
            let signature = "\(assessment.level.rawValue)-\(assessment.score / 10)-\(assessment.headlineCulprit?.displayName ?? "")"
            if advanced || signature != self.lastAppliedSignature {
                self.lastAppliedSignature = signature
                self.store.apply(assessment, history)
            }
            self.updateTitle(assessment)
        }
        engine.onSnapshot = { StatusFile.write($0) }
        trace("init complete preview=\(preview ?? "nil") button=\(item.button != nil)")
        if ProcessInfo.processInfo.environment["QUIK_NO_HUD"] != "1" {
            let hud = HUDController(
                store: store,
                onTap: { [weak self] in self?.togglePanel() },
                onToggleVisibility: { [weak self] in self?.toggleHUD() }
            )
            self.hud = hud
            syncHUD()
        }

        if let path = ProcessInfo.processInfo.environment["QUIK_HUD_MENU_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                let titles = self?.hud?.menuTitles() ?? []
                try? titles.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        if ProcessInfo.processInfo.environment["QUIK_HIDE_HUD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.setHUDVisible(false)
            }
        }
        if ProcessInfo.processInfo.environment["QUIK_CLOSE_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.hidePanel()
            }
        }
        if ProcessInfo.processInfo.environment["QUIK_SHOW_HUD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.setHUDVisible(true)
            }
        }

        if let pidText = ProcessInfo.processInfo.environment["QUIK_QUIT_PID"], let pid = pid_t(pidText) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let culprit = Culprit(
                    pid: pid, name: "quit-probe", attribution: .measured,
                    cpuOneCore: 0, diskBytesPerSecond: 0, footprintBytes: 0,
                    score: 0, reason: .none
                )
                CulpritActions.quit(culprit) { ok in
                    try? "\(ok)".write(toFile: "/tmp/quik-quit-result.txt", atomically: true, encoding: .utf8)
                }
            }
        }

        if let exportDir = ProcessInfo.processInfo.environment["QUIK_EXPORT_ICON"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                for state in ["fluid", "sluggish", "stalled"] {
                    let assessment = PreviewFixtures.make(state)
                    self.dockIcon.export(to: exportDir + "/" + state + ".png", assessment, advanced: false)
                    self.dockIcon.export(to: exportDir + "/" + state + "-advanced.png", assessment, advanced: true)
                }
                NSApp.terminate(nil)
            }
            return
        }

        if let preview {
            let assessment = PreviewFixtures.make(preview)
            store.apply(assessment, PreviewFixtures.history)
            updateTitle(assessment)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPanel(recordFrame: true)
            }
            if ProcessInfo.processInfo.environment["QUIK_TOGGLE_ADVANCED"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.toggleAdvanced()
                }
            }
            if let raw = ProcessInfo.processInfo.environment["QUIK_SWITCH_LANGUAGE"],
               let language = AppLanguage(rawValue: raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    self.store.language = language
                    self.updateTitle(self.store.assessment)
                    self.dockIcon.update(self.store.assessment)
                }
            }
            return
        }

        engine.start()

        if ProcessInfo.processInfo.environment["QUIK_SHOW_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPanel(recordFrame: false)
            }
        }
    }

    // A borderless panel instead of NSPopover: the popover always draws an arrow
    // that points at its anchor, and a full menu bar leaves no good anchor. This
    // window can sit anywhere, has no arrow, and keeps the header draggable.
    private func makePanelWindow() -> NSPanel {
        let host = NSHostingView(rootView: panel())
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let height = max(ceil(host.fittingSize.height), 390)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        panelHost = host
        panelWindow = window
        installPanelDragMonitor()
        return window
    }

    private func panel() -> PanelView {
        PanelView(
            store: store,
            chrome: chrome,
            onSample: { [weak self] culprit in
                self?.store.setSampling(true)
                CulpritActions.sample(culprit) { [weak self] _ in
                    self?.store.setSampling(false)
                }
            },
            onQuit: { [weak self] culprit in self?.confirmQuit(culprit) },
            onActivityMonitor: { CulpritActions.openActivityMonitor() },
            onToggleHUD: { [weak self] in self?.toggleHUD() },
            onToggleAdvanced: { [weak self] in self?.toggleAdvanced() },
            onLanguageChange: { [weak self] language in
                guard let self else { return }
                self.store.language = language
                self.updateTitle(self.store.assessment)
                self.dockIcon.update(self.store.assessment)
            },
            showingAgentInstall: showingAgentInstall,
            onShowAgentInstall: { [weak self] in self?.setAgentInstallVisible(true) },
            onCloseAgentInstall: { [weak self] in self?.setAgentInstallVisible(false) },
            onContentHeight: { [weak self] height in self?.fitPanel(to: height) },
            onClose: { [weak self] in self?.hidePanel() }
        )
    }

    // NSPopover keeps the size it was given. Content that grows after opening
    // (a tall translation, the first assessment, advanced mode) would be
    // clipped at the bottom, so the view reports its ideal height and the
    // panel follows, staying pinned to the same anchor.
    private func fitPanel(to height: CGFloat) {
        guard let window = panelWindow else { return }
        let size = NSSize(width: 400, height: max(ceil(height), 390))
        guard abs(window.frame.height - size.height) > 0.5 else { return }
        window.setContentSize(size)
        if window.isVisible {
            if case .attached = panelPlacement {
                // Keep the edge that faces the floating window pinned; the
                // horizontal position is the user's now, not a fresh centring.
                pinAttachedEdge(window)
            } else {
                positionPanel(window, placement: panelPlacement)
            }
        }
    }

    private func setAgentInstallVisible(_ visible: Bool) {
        showingAgentInstall = visible
        rebuildPanel()
    }

    private func updateTitle(_ assessment: StallAssessment) {
        guard let button = item.button else { return }
        let color: NSColor
        let glyph: String
        switch assessment.level {
        case .fluid:
            color = .secondaryLabelColor
            glyph = "●"
        case .sluggish:
            color = .systemOrange
            glyph = "▲"
        case .stalled:
            color = .systemRed
            glyph = "■"
        }
        let advanced = QuikStore.advancedMode
        let title = " \(glyph) " + Copy.menuTitle(assessment, advanced: advanced)
        if title != lastTitle {
            lastTitle = title
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: color
                ]
            )
        }
        dockIcon.update(assessment)
        trace("title=\(title) visible=\(item.isVisible) window=\(String(describing: button.window?.frame)) screen=\(String(describing: button.window?.screen?.frame))")
    }

    func openPanel() {
        showPanel(recordFrame: false)
    }

    private func toggleAdvanced() {
        store.advanced.toggle()
        hud?.applyAdvancedMode()
        if let window = panelWindow, window.isVisible, case .attached = panelPlacement {
            positionPanel(window, placement: panelPlacement)
            chrome.arrow = arrowPlacement(for: panelPlacement)
        }
        rebuildPanel()
    }

    private func rebuildPanel() {
        guard panelHost != nil else { return }
        panelHost?.rootView = panel()
        showPanel(recordFrame: false)
    }

    private func hidePanel() {
        guard let window = panelWindow, window.isVisible else { return }
        detachPanel()
        window.orderOut(nil)
        guard restoreHUDAfterPanel, !suppressHUDRestore else { return }
        restoreHUDAfterPanel = false
        syncHUD()
    }

    private func confirmQuit(_ culprit: Culprit) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = Copy.confirmQuitTitle(culprit.displayName)
        alert.informativeText = Copy.confirmQuitBody()
        alert.addButton(withTitle: Copy.quit())
        alert.addButton(withTitle: Copy.cancel())
        alert.alertStyle = .warning
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        guard confirmed else { return showPanel(recordFrame: false) }
        CulpritActions.quit(culprit) { [weak self] quit in
            if !quit {
                let failed = NSAlert()
                failed.messageText = Copy.quitFailedTitle(culprit.displayName)
                failed.informativeText = Copy.quitFailedBody()
                failed.runModal()
            }
            self?.showPanel(recordFrame: false)
        }
    }

    // The panel's top edge is pinned to the anchor, so a taller panel grows
    // downward from the same place.
    private func positionPanel(_ window: NSWindow, placement: PanelPlacement) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 8
        var frame = window.frame
        switch placement {
        case .attached(let edge):
            guard let hudFrame = hud?.frame else { return }
            frame.origin.x = clampedX(anchorMidX: hudFrame.midX, width: frame.width, visible: visible)
            frame.origin.y = edge == .top
                ? hudFrame.minY - frame.height - gap
                : hudFrame.maxY + gap
        case .below(let anchor):
            frame.origin.x = clampedX(anchorMidX: anchor.midX, width: frame.width, visible: visible)
            let below = anchor.minY - frame.height - gap
            let above = anchor.maxY + gap
            if below >= visible.minY + gap {
                frame.origin.y = below
            } else if above + frame.height <= visible.maxY - gap {
                frame.origin.y = above
            } else {
                frame.origin.y = min(max(below, visible.minY + gap), visible.maxY - frame.height - gap)
            }
        case .centered:
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
        }
        window.setFrame(frame, display: true)
    }

    private func pinAttachedEdge(_ window: NSWindow) {
        guard case .attached(let edge) = panelPlacement, let hudFrame = hud?.frame else { return }
        let gap: CGFloat = 8
        var frame = window.frame
        frame.origin.y = edge == .top ? hudFrame.minY - frame.height - gap : hudFrame.maxY + gap
        window.setFrame(frame, display: true)
    }

    private func clampedX(anchorMidX: CGFloat, width: CGFloat, visible: NSRect) -> CGFloat {
        let gap: CGFloat = 8
        return min(max(anchorMidX - width / 2, visible.minX + gap), visible.maxX - width - gap)
    }

    // Only the floating window gets an arrow. The tip has to land on its
    // centre, which is not the panel's centre once the panel is clamped at a
    // screen edge.
    private func arrowPlacement(for placement: PanelPlacement) -> PanelArrow? {
        guard case .attached(let edge) = placement,
              let hudFrame = hud?.frame, let window = panelWindow else { return nil }
        return PanelArrow(offset: hudFrame.midX - window.frame.minX, edge: edge)
    }

    // The authoritative way to keep two windows together: make one a child of
    // the other. AppKit moves a child with its parent inside the window
    // server, so dragging the floating window moves the panel with no redraw
    // lag at all. The other direction drives the parent from the panel's
    // header, and the child rides along in the same transaction.
    private func attachPanel() {
        guard case .attached = panelPlacement,
              let window = panelWindow, let hudWindow = hud?.window else { return }
        if window.parent !== hudWindow {
            hudWindow.addChildWindow(window, ordered: .below)
        }
        // The header drag below owns the motion while attached.
        window.isMovableByWindowBackground = false
    }

    private func detachPanel() {
        guard let window = panelWindow else { return }
        if let parent = window.parent { parent.removeChildWindow(window) }
        window.isMovableByWindowBackground = true
        panelDragPoint = nil
    }

    private func installPanelDragMonitor() {
        guard panelDragMonitor == nil else { return }
        panelDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, case .attached = self.panelPlacement,
                  let window = self.panelWindow, event.window === window else { return event }
            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown:
                let frame = window.frame
                // Header only, left of the language and close buttons.
                if point.y >= frame.maxY - 56, point.x <= frame.maxX - 140 {
                    self.panelDragPoint = point
                }
            case .leftMouseDragged:
                guard let last = self.panelDragPoint else { break }
                self.panelDragPoint = point
                self.hud?.move(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            case .leftMouseUp:
                self.panelDragPoint = nil
            default:
                break
            }
            return event
        }
    }

    private func setHUDVisible(_ visible: Bool) {
        if store.hudVisible != visible {
            store.hudVisible = visible
        }
        syncHUD()
        // The pair only exists while the floating window is there. With it
        // gone, the open panel falls back to the status item.
        guard !visible, let window = panelWindow, window.isVisible,
              case .attached = panelPlacement else { return }
        detachPanel()
        panelPlacement = placement(for: window)
        positionPanel(window, placement: panelPlacement)
        chrome.arrow = arrowPlacement(for: panelPlacement)
    }

    private func toggleHUD() {
        setHUDVisible(!store.hudVisible)
    }

    private func syncHUD() {
        guard let hud else { return }
        if store.hudVisible {
            hud.show()
        } else {
            hud.hide()
        }
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp, let event = NSApp.currentEvent {
            showStatusMenu(event)
            return
        }
        if panelWindow?.isVisible == true {
            hidePanel()
        } else {
            showPanel(recordFrame: false)
        }
    }

    private func showStatusMenu(_ event: NSEvent) {
        guard let button = item.button else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: Copy.openPanel(), action: #selector(openPanelAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let language = NSMenuItem(title: Copy.interfaceLanguage(), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for option in AppLanguage.allCases {
            let entry = NSMenuItem(
                title: option.menuTitle,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = option.rawValue
            entry.state = option == store.language ? .on : .off
            languages.addItem(entry)
        }
        language.submenu = languages
        menu.addItem(language)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: Copy.showHUD(), action: #selector(toggleHUDAction), keyEquivalent: "")
        toggle.target = self
        toggle.state = store.hudVisible ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        let uninstall = NSMenuItem(title: Copy.uninstall() + "…", action: #selector(uninstallAction), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func openPanelAction() {
        showPanel(recordFrame: false)
    }

    @objc private func toggleHUDAction() {
        toggleHUD()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        store.language = language
        updateTitle(store.assessment)
        dockIcon.update(store.assessment)
    }

    // macOS 在应用被删除后不会执行任何代码，所以清理只能由应用活着时完成：
    // 这里删掉 Quik 放进系统的全部东西，再退出，用户最后拖走应用本体。
    @objc private func uninstallAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = Copy.uninstallTitle()
        alert.informativeText = Copy.uninstallBody()
        alert.addButton(withTitle: Copy.uninstall())
        alert.addButton(withTitle: Copy.cancel())
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AgentInstall.uninstall()
        NSApp.terminate(nil)
    }

    /// The floating window, the Dock icon, and the status item all toggle the
    /// same panel. The menu item that says "Open Panel" still only opens it.
    func togglePanel() {
        if panelWindow?.isVisible == true {
            hidePanel()
        } else {
            showPanel(recordFrame: false)
        }
    }

    private func showPanel(recordFrame: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let window = panelWindow ?? makePanelWindow()
        if window.isVisible {
            // A content rebuild must not undo a drag the user made.
            pinAttachedEdge(window)
        } else {
            panelPlacement = placement(for: window)
            positionPanel(window, placement: panelPlacement)
        }
        chrome.arrow = arrowPlacement(for: panelPlacement)
        if case .attached = panelPlacement {
            attachPanel()
        } else {
            detachPanel()
        }
        window.orderFrontRegardless()
        trace("showPanel: placement=\(panelPlacement) window=\(window.frame)")
        if let hud, store.hudVisible, let hudFrame = hud.frame, hudFrame.intersects(window.frame) {
            restoreHUDAfterPanel = true
            hud.hide()
        }
        if recordFrame {
            let number = window.windowNumber
            let text = "\(number)"
            try? text.write(toFile: "/tmp/quik-panel-windowid.txt", atomically: true, encoding: String.Encoding.utf8)
            trace("window id recorded \(text)")
        }
    }

    private func placement(for window: NSWindow) -> PanelPlacement {
        if store.hudVisible, let hudFrame = hud?.frame, hud?.anchorView != nil {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let fitsBelow = hudFrame.minY - window.frame.height - 8 >= visible.minY + 8
            return .attached(edge: fitsBelow ? .top : .bottom)
        }
        if isStatusItemCrowdedOut() {
            return .centered
        }
        return .below(statusItemRect())
    }

    private func statusItemRect() -> NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // A full menu bar pushes the status item next to the app menus, on the left
    // half of the screen. That is the signal to center the panel instead.
    private func isStatusItemCrowdedOut() -> Bool {
        guard let button = item.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return false }
        return statusItemRect().midX < screen.visibleFrame.midX
    }

    /// Clicking outside closes the panel. The app resigning active is that
    /// click, and it is the only signal that does not also fire when the user
    /// clicks Quik's own Dock tile. Watching raw mouse-downs instead closed the
    /// panel and then the Dock's reopen reopened it, so one click flickered.
    func panelDidResignActive() {
        hidePanel()
    }
}
