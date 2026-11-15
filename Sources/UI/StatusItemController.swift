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
                    score: 0, reason: ""
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
    private static func panelController(_ view: PanelView) -> NSViewController {
        let host = NSHostingView(rootView: view)
        let height: CGFloat = view.store.advanced ? 500 : 390
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
            onToggleAdvanced: { [weak self] in self?.toggleAdvanced() }
        )
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
        let title = " \(glyph) " + assessment.menuTitle(advanced: advanced)
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
        suppressHUDRestore = true
        popover.performClose(nil)
        popover.contentViewController = Self.panelController(panel())
        showPopover(recordFrame: false)
        DispatchQueue.main.async { [weak self] in
            self?.suppressHUDRestore = false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard restoreHUDAfterPanel, !suppressHUDRestore else { return }
        restoreHUDAfterPanel = false
        syncHUD()
    }

    private func confirmQuit(_ culprit: Culprit) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "退出「\(culprit.displayName)」？"
        alert.informativeText = "程序里没保存的内容会丢失。退出后系统应该会马上变快。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        guard confirmed else { return showPopover(recordFrame: false) }
        CulpritActions.quit(culprit) { [weak self] quit in
            if !quit {
                let failed = NSAlert()
                failed.messageText = "没能退出「\(culprit.displayName)」"
                failed.informativeText = "这个进程可能是系统管理的，普通权限动不了它。可以在活动监视器里再试一次。"
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
        let open = NSMenuItem(title: "打开面板", action: #selector(openPanelAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "显示悬浮窗", action: #selector(toggleHUDAction), keyEquivalent: "")
        toggle.target = self
        toggle.state = store.hudVisible ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        let uninstall = NSMenuItem(title: "卸载 Quik…", action: #selector(uninstallAction), keyEquivalent: "")
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

    // macOS 在应用被删除后不会执行任何代码，所以清理只能由应用活着时完成：
    // 这里删掉 Quik 放进系统的全部东西，再退出，用户最后拖走应用本体。
    @objc private func uninstallAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "卸载 Quik？"
        alert.informativeText = "会删除 Quik 放进系统的所有东西：两个标准技能目录里的 quik 技能、~/.local/bin/quik 命令行工具、~/Library/Application Support/Quik 数据，然后退出。之后把 Quik 从「应用程序」拖进废纸篓就完成了。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AgentInstall.uninstall()
        NSApp.terminate(nil)
    }

    private func showPopover(recordFrame: Bool) {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        let screenRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        trace("showPopover: button screen=\(screenRect) safeTop=\(button.window?.screen?.safeAreaInsets.top ?? -1)")
        let anchorRect: NSRect
        if store.hudVisible, let anchor = hud?.anchorView, let hudFrame = hud?.frame {
            anchorRect = hudFrame
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            anchorRect = screenRect
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        guard let window = popover.contentViewController?.view.window else {
            trace("showPopover: window nil")
            return
        }
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
