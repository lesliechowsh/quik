import Foundation

/// Looks up user-facing text in one language bundle. A missing bundle falls
/// back to the key itself, and every key is written in English, so the CLI and
/// the agent snapshot stay readable and never depend on the UI language.
struct CopyTable: Sendable {
    var bundle: Bundle?

    static var ui: CopyTable {
        let selected = AppLanguage.stored
        if selected == .system { return CopyTable(bundle: .main) }
        if let path = Bundle.main.path(forResource: selected.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) { return CopyTable(bundle: bundle) }
        return CopyTable(bundle: nil)
    }

    static let base = CopyTable(bundle: nil)

    func string(_ key: String) -> String {
        guard let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}

enum Copy {
    static func level(_ level: StallLevel, _ t: CopyTable = .ui) -> String {
        switch level {
        case .fluid: return t.string("Fluid")
        case .sluggish: return t.string("Sluggish")
        case .stalled: return t.string("Stalled")
        }
    }

    /// The Dock tile is 128 points wide and shows one line at 58 points, so it
    /// gets short words of its own instead of the panel wording.
    static func dockLevel(_ level: StallLevel, _ t: CopyTable = .ui) -> String {
        switch level {
        case .fluid: return t.string("Fine")
        case .sluggish: return t.string("Lagging")
        case .stalled: return t.string("Frozen")
        }
    }

    static func causeName(_ kind: CauseKind, _ t: CopyTable = .ui) -> String {
        switch kind {
        case .cpu: return "CPU"
        case .memory: return t.string("Memory")
        case .disk: return t.string("Disk")
        case .scheduling: return t.string("Scheduling")
        case .thermal: return t.string("Thermal")
        }
    }

    static func causeSentence(_ kind: CauseKind, _ t: CopyTable = .ui) -> String {
        switch kind {
        case .cpu: return t.string("The CPU is maxed out, so the system cannot keep up with your input.")
        case .memory: return t.string("Memory is running short, so the system keeps freeing space.")
        case .disk: return t.string("The disk is too busy, so reads and writes are queuing.")
        case .scheduling: return t.string("The system responds slowly, so clicks take a while to react.")
        case .thermal: return t.string("The machine is too hot, so performance is capped.")
        }
    }

    static func summary(_ assessment: StallAssessment, _ t: CopyTable = .ui) -> String {
        if assessment.level == .fluid {
            return t.string("It runs smoothly right now. Nothing to do.")
        }
        var parts: [String] = []
        if let cause = assessment.stableCause {
            parts.append(causeSentence(cause, t))
        } else {
            parts.append(t.string("The system has not recovered from recent resource contention."))
        }
        if let culprit = assessment.headlineCulprit {
            parts.append(t.format("%@ is using the most resources.", culprit.displayName))
        }
        return parts.joined()
    }

    static func menuTitle(_ assessment: StallAssessment, advanced: Bool, _ t: CopyTable = .ui) -> String {
        switch assessment.level {
        case .fluid:
            return advanced ? "\(assessment.score)" : level(.fluid, t)
        case .sluggish, .stalled:
            if let culprit = assessment.headlineCulprit {
                let name = attributionShort(culprit.displayName)
                guard advanced else { return name }
                let percent = Int((culprit.cpuOneCore * 100).rounded())
                return "\(name) \(percent)%"
            }
            return advanced ? "\(assessment.score)" : level(assessment.level, t)
        }
    }

    static func causeHeadline(_ cause: CauseEvidence, _ t: CopyTable = .ui) -> String {
        switch cause.metrics {
        case let .cpu(percent, _, _):
            return t.format("CPU %ld%%", percent)
        case let .memory(pressure, compressedGB, _, _):
            switch pressure {
            case 2: return t.string("Memory is critically low")
            case 1: return t.string("Memory pressure is high")
            default: return t.format("Memory compressed (%ld GB)", Int(compressedGB.rounded()))
            }
        case let .disk(percent, _, _):
            return t.format("Disk is busy (%ld%%)", percent)
        case let .scheduling(jankMs, _):
            return t.format("Response lag %ld ms", jankMs)
        case .thermal:
            return t.string("Thermal throttling")
        }
    }

    static func causeDetail(_ cause: CauseEvidence, _ t: CopyTable = .ui) -> String {
        switch cause.metrics {
        case let .cpu(_, busyCores, cores):
            return t.format("%ld of %ld cores are busy", busyCores, cores)
        case let .memory(_, compressedGB, swapMB, paging):
            var parts = [
                t.format("%ld GB of memory is compressed", Int(compressedGB.rounded())),
                t.format("%ld MB of disk is used as memory", Int(swapMB.rounded())),
            ]
            if paging {
                parts.append(t.string("Data keeps paging in and out"))
            }
            return parts.joined(separator: ", ")
        case let .disk(_, readRate, writeRate):
            return t.format("Reading %@, writing %@", rate(readRate), rate(writeRate))
        case let .scheduling(jankMs, baselineMs):
            return t.format("The system took %ld ms to respond (usually %ld ms)", jankMs, baselineMs)
        case let .thermal(state):
            return thermalDetail(state, t)
        }
    }

    static func thermalDetail(_ state: ProcessInfo.ThermalState, _ t: CopyTable = .ui) -> String {
        switch state {
        case .fair: return t.string("The chip is starting to throttle")
        case .serious: return t.string("Throttling is visible, performance is reduced")
        case .critical: return t.string("Severe heat, the system is limiting speed")
        default: return t.string("Temperature is normal")
        }
    }

    static func culpritReason(_ reason: CulpritReason, _ t: CopyTable = .ui) -> String {
        switch reason {
        case .none: return ""
        case let .cpuShare(percent): return t.format("%ld%% CPU", percent)
        case let .cpuCores(cores): return t.format("%.1f cores", cores)
        case let .disk(bytesPerSecond): return t.format("Disk %@", rate(bytesPerSecond))
        case let .memory(bytes): return t.format("%.1f GB memory", bytes / 1_073_741_824)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB/s", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    private static func attributionShort(_ name: String) -> String {
        String(name.replacingOccurrences(of: ".app", with: "").prefix(9))
    }

    // MARK: - Roles and system process names

    static func processRole(_ role: ProcessRole, _ t: CopyTable = .ui) -> String {
        switch role {
        case .pageRendering: return t.string("Page rendering")
        case .graphics: return t.string("Graphics")
        case .plugin: return t.string("Plugin")
        case .background: return t.string("Background process")
        case .webContent: return t.string("Web content")
        case let .workingDirectory(folder): return t.format("Running from the %@ folder", folder)
        }
    }

    static func helperRole(_ processName: String) -> ProcessRole? {
        if processName.contains("Helper (Renderer)") { return .pageRendering }
        if processName.contains("Helper (GPU)") { return .graphics }
        if processName.contains("Helper (Plugin)") { return .plugin }
        if processName.contains("Helper") { return .background }
        if processName.contains("WebContent") { return .webContent }
        return nil
    }

    static func systemProcessName(_ processName: String, _ t: CopyTable = .ui) -> String? {
        switch true {
        case processName.hasPrefix("mdworker"), processName.hasPrefix("mds"):
            return t.string("Spotlight")
        case processName.hasPrefix("kernel_task"):
            return t.string("System kernel")
        case processName.hasPrefix("WindowServer"):
            return t.string("Window server")
        case processName.hasPrefix("backupd"):
            return t.string("Time Machine")
        case processName.hasPrefix("coreaudiod"):
            return t.string("System audio")
        case processName.hasPrefix("photoanalysisd"):
            return t.string("Photos analysis")
        default:
            return nil
        }
    }

    // MARK: - Interface

    static func openPanel(_ t: CopyTable = .ui) -> String { t.string("Open Panel") }
    static func followSystemLanguage(_ t: CopyTable = .ui) -> String { t.string("Follow the system language") }
    static func interfaceLanguage(_ t: CopyTable = .ui) -> String { t.string("Interface language") }
    static func showHUD(_ t: CopyTable = .ui) -> String { t.string("Show Floating Window") }
    static func hideHUD(_ t: CopyTable = .ui) -> String { t.string("Hide Floating Window") }
    static func activityMonitor(_ t: CopyTable = .ui) -> String { t.string("Activity Monitor") }
    static func installForAssistant(_ t: CopyTable = .ui) -> String { t.string("Install for AI Assistant") }
    static func normalMode(_ t: CopyTable = .ui) -> String { t.string("Normal Mode") }
    static func advancedMode(_ t: CopyTable = .ui) -> String { t.string("Advanced Mode") }
    static func quit(_ t: CopyTable = .ui) -> String { t.string("Quit") }
    static func cancel(_ t: CopyTable = .ui) -> String { t.string("Cancel") }
    static func sample(_ t: CopyTable = .ui) -> String { t.string("See what it is doing (3 s)") }
    static func saveFirstHint(_ t: CopyTable = .ui) -> String { t.string("Save your work before quitting.") }
    static func currentState(_ t: CopyTable = .ui) -> String { t.string("Current state") }
    static func whatWentWrong(_ t: CopyTable = .ui) -> String { t.string("What went wrong") }
    static func usingTheMost(_ t: CopyTable = .ui) -> String { t.string("Using the most") }
    static func fixThisFirst(_ t: CopyTable = .ui) -> String { t.string("Fix this first") }
    static func systemResourcesHidden(_ t: CopyTable = .ui) -> String {
        t.string("These resources belong to the system. Normal permissions cannot see which app. Open Activity Monitor to check.")
    }
    static func normalForLast(_ seconds: Int, _ t: CopyTable = .ui) -> String {
        t.format("Normal for the last %ld s", seconds)
    }
    static func lastSeconds(_ seconds: Int, _ t: CopyTable = .ui) -> String {
        t.format("Last %ld s", seconds)
    }
    static func hiddenCPUShare(_ percent: Int, _ t: CopyTable = .ui) -> String {
        t.format("About %ld%% of the CPU is used by system processes. Normal permissions cannot see the details.", percent)
    }
    static func quitCulprit(_ name: String, _ t: CopyTable = .ui) -> String {
        t.format("Quit %@", name)
    }
    static func nothingToHandle(_ t: CopyTable = .ui) -> String { t.string("Nothing to handle") }
    static func hudCPU(_ percent: Int, lagMs: Int, _ t: CopyTable = .ui) -> String {
        t.format("CPU %ld%% · lag %ld ms", percent, lagMs)
    }

    // MARK: - Agent install page

    static func agentTitle(_ t: CopyTable = .ui) -> String { t.string("Let your AI assistant watch your Mac") }
    static func agentIntro(_ t: CopyTable = .ui) -> String {
        t.string("Once installed, your AI assistant can read Quik's live data. Ask it whether the Mac feels slow, and it will answer.")
    }
    static func agentNoteCompatible(_ t: CopyTable = .ui) -> String {
        t.string("Codex, Cursor, Cline, Zed, and more")
    }
    static func agentNoteClaude(_ t: CopyTable = .ui) -> String { t.string("Claude Code") }
    static func agentAbsent(_ t: CopyTable = .ui) -> String { t.string("Not installed yet") }
    static func agentPartial(_ t: CopyTable = .ui) -> String { t.string("Half installed. Click Install to finish.") }
    static func agentInstalled(_ t: CopyTable = .ui) -> String { t.string("Installed, stays with Quik") }
    static func install(_ t: CopyTable = .ui) -> String { t.string("Install") }
    static func reinstall(_ t: CopyTable = .ui) -> String { t.string("Reinstall") }
    static func remove(_ t: CopyTable = .ui) -> String { t.string("Remove") }
    static func back(_ t: CopyTable = .ui) -> String { t.string("Back") }
    static func agentCLIHint(_ t: CopyTable = .ui) -> String {
        t.string("The command-line tool goes to ~/.local/bin/quik. Nothing is written anywhere else. Remove deletes the skill and the command together.")
    }

    // MARK: - Alerts

    static func confirmQuitTitle(_ name: String, _ t: CopyTable = .ui) -> String {
        t.format("Quit \"%@\"?", name)
    }
    static func confirmQuitBody(_ t: CopyTable = .ui) -> String {
        t.string("Unsaved work will be lost. The system should speed up right after.")
    }
    static func quitFailedTitle(_ name: String, _ t: CopyTable = .ui) -> String {
        t.format("Could not quit \"%@\"", name)
    }
    static func quitFailedBody(_ t: CopyTable = .ui) -> String {
        t.string("This process may be managed by the system, and normal permissions cannot stop it. Try again in Activity Monitor.")
    }
    static func uninstallTitle(_ t: CopyTable = .ui) -> String { t.string("Uninstall Quik?") }
    static func uninstallBody(_ t: CopyTable = .ui) -> String {
        t.string("This deletes everything Quik put on this Mac: the quik skill in both standard skill folders, the ~/.local/bin/quik command, and the ~/Library/Application Support/Quik data, then quits. After that, drag Quik from Applications to the Trash.")
    }
    static func uninstall(_ t: CopyTable = .ui) -> String { t.string("Uninstall") }
}
