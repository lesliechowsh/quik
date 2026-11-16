import AppKit
import SwiftUI

final class HUDController: NSObject, NSMenuDelegate {
    private var panel: NSPanel?
    private let store: QuikStore
    private let onTap: () -> Void
    private let onToggleVisibility: () -> Void
    private let menu = NSMenu()
    private var rightClickMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private static let defaultInset: CGFloat = 28
    private static let originXKey = "hudOriginX"
    private static let originYKey = "hudOriginY"

    private let size = CGSize(width: 128, height: 36)

    init(store: QuikStore, onTap: @escaping () -> Void, onToggleVisibility: @escaping () -> Void) {
        self.store = store
        self.onTap = onTap
        self.onToggleVisibility = onToggleVisibility
        super.init()
        menu.delegate = self
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The window floats over other apps. Let a little of what is behind it
        // through, so it reads as an overlay instead of a solid tile.
        panel.alphaValue = 0.86
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: HUDView(store: store, onTap: onTap))
        hosting.menu = menu
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        installRightClick()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.savePosition()
        }

        let number = panel.windowNumber
        try? "\(number)".write(toFile: "/tmp/quik-hud-windowid.txt", atomically: true, encoding: String.Encoding.utf8)
    }

    var frame: NSRect? {
        panel?.frame
    }

    var anchorView: NSView? {
        guard let panel, panel.isVisible else { return nil }
        return panel.contentView
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // SwiftUI hosting views swallow right clicks, so watch the app's event stream
    // for clicks that landed on this panel instead of relying on the view menu.
    private func installRightClick() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel else { return event }
            self.menuNeedsUpdate(self.menu)
            if let view = panel.contentView {
                NSMenu.popUpContextMenu(self.menu, with: event, for: view)
            }
            return nil
        }
    }

    deinit {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: Copy.openPanel(), action: #selector(openPanelAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: store.hudVisible ? Copy.hideHUD() : Copy.showHUD(),
            action: #selector(toggleVisibilityAction),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
    }

    func menuTitles() -> [String] {
        menuNeedsUpdate(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @objc private func openPanelAction() {
        onTap()
    }

    @objc private func toggleVisibilityAction() {
        onToggleVisibility()
    }

    private func position(_ panel: NSPanel) {
        let frame = NSRect(origin: savedOrigin() ?? defaultOrigin(), size: size)
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            panel.setFrame(frame, display: true)
        } else {
            panel.setFrame(NSRect(origin: defaultOrigin(), size: size), display: true)
        }
    }

    private func defaultOrigin() -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(
            x: visible.maxX - size.width - Self.defaultInset,
            y: visible.maxY - size.height - Self.defaultInset
        )
    }

    private func savedOrigin() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil else { return nil }
        return CGPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
    }

    private func savePosition() {
        guard let panel, panel.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
        defaults.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
    }
}

struct HUDView: View {
    @ObservedObject var store: QuikStore
    var onTap: () -> Void

    private var assessment: StallAssessment { store.assessment }

    private var accent: Color {
        switch assessment.level {
        case .fluid: return .green
        case .sluggish: return .orange
        case .stalled: return .red
        }
    }

    private var detail: String {
        if assessment.level != .fluid, let culprit = assessment.headlineCulprit {
            let role = culprit.app?.role.map { " · \(Copy.processRole($0))" } ?? ""
            if store.advanced {
                return "\(culprit.displayName)\(role) · \(Copy.culpritReason(culprit.reason))"
            }
            return "\(culprit.displayName)\(role)"
        }
        return store.advanced
            ? Copy.hudCPU(Int((assessment.cpuBusy * 100).rounded()), lagMs: Int(assessment.schedulerJankMs.rounded()))
            : Copy.nothingToHandle()
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.advanced ? "\(assessment.score)  \(Copy.level(assessment.level))" : Copy.level(assessment.level))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
