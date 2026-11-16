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

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let store = QuikStore()
    private let engine = MonitorEngine()
    private var hud: HUDController?
    private var lastTitle = ""
    private var lastAppliedSignature = ""
    private var restoreHUDAfterPanel = false
    private var suppressHUDRestore = false
    private var showingAgentInstall = ProcessInfo.processInfo.environment["QUIK_PREVIEW_AGENT"] != nil
    private var panelAnchor: NSRect = .zero
    private var panelAnchorWindow: NSWindow?
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

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = Self.panelController(panel())

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
                onTap: { [weak self] in self?.showPopover(recordFrame: false) },
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
                self?.popover.performClose(nil)
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
                self?.showPopover(recordFrame: true)
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
                self?.showPopover(recordFrame: false)
            }
        }
    }

    // NSHostingController as popover content makes NSPopover place the window above the
    // screen top on macOS 26. A plain controller with an explicit preferredContentSize
    // keeps the placement inside the screen. Reproduce with /tmp/popover-probe.swift.
    // The height comes from the view itself: translated text wraps to more lines
    // than the Chinese original, and a fixed height would clip it.
    private static func panelController(_ view: PanelView) -> NSViewController {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let height = max(ceil(host.fittingSize.height), 390)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        let controller = NSViewController()
        controller.view = host
        controller.preferredContentSize = NSSize(width: 400, height: height)
        return controller
    }

    private func panel() -> PanelView {
        PanelView(
            store: store,
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
            onContentHeight: { [weak self] height in self?.fitPanel(to: height) }
        )
    }

    // NSPopover keeps the size it was given. Content that grows after opening
    // (a tall translation, the first assessment, advanced mode) would be
    // clipped at the bottom, so the view reports its ideal height and the
    // popover follows, staying pinned to the same anchor.
    private func fitPanel(to height: CGFloat) {
        let size = NSSize(width: 400, height: max(ceil(height), 390))
        guard abs(popover.contentSize.height - size.height) > 0.5 else { return }
        popover.contentSize = size
        popover.contentViewController?.preferredContentSize = size
        if popover.isShown, let window = popover.contentViewController?.view.window {
            positionPanel(window, near: panelAnchor)
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
        showPopover(recordFrame: false)
    }

    private func toggleAdvanced() {
        store.advanced.toggle()
        rebuildPanel()
    }

    private func rebuildPanel() {
        suppressHUDRestore = true
        popover.performClose(nil)
        popover.contentViewController = Self.panelController(panel())
        showPopover(recordFrame: false)
        DispatchQueue.main.async { [weak self] in
            self?.suppressHUDRestore = false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panelAnchorWindow?.orderOut(nil)
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
        guard confirmed else { return showPopover(recordFrame: false) }
        CulpritActions.quit(culprit) { [weak self] quit in
            if !quit {
                let failed = NSAlert()
                failed.messageText = Copy.quitFailedTitle(culprit.displayName)
                failed.informativeText = Copy.quitFailedBody()
                failed.runModal()
            }
            self?.showPopover(recordFrame: false)
        }
    }

    // NSPopover picks its own origin when the content changes height, and on
    // macOS 26 that can drift sideways or climb over the floating window. Pin
    // the top edge just below the floating window (or the status item) so a
    // taller panel grows downward from the same place.
    private func positionPanel(_ window: NSWindow, near anchor: NSRect) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 8
        var frame = window.frame
        frame.origin.x = min(max(anchor.midX - frame.width / 2, visible.minX + gap), visible.maxX - frame.width - gap)
        let below = anchor.minY - frame.height - gap
        let above = anchor.maxY + gap
        if below >= visible.minY + gap {
            frame.origin.y = below
        } else if above + frame.height <= visible.maxY - gap {
            frame.origin.y = above
        } else {
            frame.origin.y = min(max(below, visible.minY + gap), visible.maxY - frame.height - gap)
        }
        window.setFrame(frame, display: true)
    }

    private func clampToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        guard !visible.contains(frame) else { return }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = max(min(frame.minY, visible.maxY - frame.height), visible.minY)
        window.setFrame(frame, display: true)
        trace("showPopover: clamped to \(frame)")
    }

    private func setHUDVisible(_ visible: Bool) {
        if store.hudVisible != visible {
            store.hudVisible = visible
        }
        syncHUD()
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
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(recordFrame: false)
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
        showPopover(recordFrame: false)
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

    // NSPopover needs a visible view to point at. This one sits at the top
    // right and draws nothing, so the arrow and the click-outside area stay
    // correct without moving the popover window by hand.
    private func makeAnchorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        panelAnchorWindow = window
        return window
    }

    private func showPopover(recordFrame: Bool) {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        let screenRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        trace("showPopover: button screen=\(screenRect) safeTop=\(button.window?.screen?.safeAreaInsets.top ?? -1)")
        var anchorRect: NSRect
        if store.hudVisible, let anchor = hud?.anchorView, let hudFrame = hud?.frame {
            anchorRect = hudFrame
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            // A full menu bar pushes the status item next to the app menus, so
            // the panel would open in the middle of the screen. Move the popover
            // only by giving it a real anchor at the top right: moving its window
            // afterwards leaves the arrow and the click-outside area behind.
            let screen = button.window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let point = NSPoint(x: visible.maxX - 28, y: visible.maxY - 34)
            let anchorWindow = panelAnchorWindow ?? makeAnchorWindow()
            anchorWindow.setFrame(NSRect(origin: point, size: NSSize(width: 1, height: 1)), display: false)
            anchorWindow.orderFrontRegardless()
            anchorRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
            let anchor = anchorWindow.contentView!
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        guard let window = popover.contentViewController?.view.window else {
            trace("showPopover: window nil")
            return
        }
        panelAnchor = anchorRect
        positionPanel(window, near: anchorRect)
        trace("showPopover: window \(window.frame)")
        clampToScreen(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let w = self.popover.contentViewController?.view.window else { return }
            trace("showPopover: settled window \(w.frame) visible=\(w.occlusionState.contains(.visible))")
        }
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
}
