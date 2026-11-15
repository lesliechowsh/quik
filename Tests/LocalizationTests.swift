import AppKit
import SwiftUI
import XCTest
@testable import Quik

@MainActor
final class LocalizationTests: XCTestCase {
    private let languages = ["zh-Hans", "de", "fr", "ja"]

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj"),
            "缺少 \(language).lproj"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func table(_ language: String) throws -> CopyTable {
        CopyTable(bundle: try bundle(language))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(bundle(language).url(forResource: "Localizable", withExtension: "strings"))
        let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(raw as? [String: String])
    }

    /// Each language file must translate exactly the same keys. A missing entry
    /// would silently show English in one language only, which no screenshot
    /// review reliably catches.
    func testEveryLanguageHasTheSameKeys() throws {
        let reference = Set(try strings("zh-Hans").keys)
        XCTAssertFalse(reference.isEmpty)
        for language in languages.dropFirst() {
            XCTAssertEqual(Set(try strings(language).keys), reference, "\(language) 的键集合与中文不一致")
        }
    }

    /// A format string that adds or drops a placeholder crashes at runtime on
    /// a locale the developer never runs.
    func testPlaceholdersMatchAcrossLanguages() throws {
        // Product names, unit labels, and a handful of words that are spelled
        // the same in the target language stay as the English key on purpose.
        let intentionallySame: Set<String> = [
            "CPU %ld%%", "%ld%% CPU", "Claude Code", "Time Machine", "Spotlight", "Plugin",
        ]
        let reference = try strings("zh-Hans")
        for (key, _) in reference {
            let expected = placeholders(in: key)
            for language in languages {
                let value = try XCTUnwrap(try strings(language)[key], "\(language) 缺少「\(key)」")
                XCTAssertTrue(
                    value != key || intentionallySame.contains(key),
                    "\(language) 的「\(key)」没有翻译"
                )
                XCTAssertEqual(placeholders(in: value), expected, "\(language) 的「\(key)」占位符与原文不一致")
            }
        }
    }

    private func placeholders(in text: String) -> [String] {
        var out: [String] = []
        var index = text.startIndex
        while let percent = text[index...].firstIndex(of: "%") {
            let next = text.index(after: percent)
            guard next < text.endIndex else { break }
            if text[next] == "%" {
                index = text.index(after: next)
                continue
            }
            var cursor = next
            var positional = false
            while cursor < text.endIndex, "0123456789.$-+".contains(text[cursor]) {
                positional = positional || text[cursor] == "$"
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex {
                // Word order differs between languages, so a translated string
                // may reorder arguments with %2$ld. Compare the conversion
                // types, not the argument numbers.
                var spec = String(text[percent..<text.index(after: cursor)])
                if positional, let dollar = spec.firstIndex(of: "$") {
                    spec = "%" + spec[spec.index(after: dollar)...]
                }
                out.append(spec)
                index = text.index(after: cursor)
            } else {
                index = next
            }
        }
        return out.sorted()
    }

    func testCoreLabelsTranslate() throws {
        let expected: [String: (String, String)] = [
            "zh-Hans": ("流畅", "内存"),
            "de": ("Flüssig", "Arbeitsspeicher"),
            "fr": ("Fluide", "Mémoire"),
            "ja": ("快適", "メモリ"),
        ]
        for (language, pair) in expected {
            let copy = try table(language)
            XCTAssertEqual(Copy.level(.fluid, copy), pair.0, "\(language) 状态词")
            XCTAssertEqual(Copy.causeName(.memory, copy), pair.1, "\(language) 原因名")
        }
    }

    func testSelectingALanguageOverridesTheSystemOne() {
        let defaults = UserDefaults.standard
        let key = AppLanguage.storageKey
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set("ja", forKey: key)
        XCTAssertEqual(Copy.level(.fluid), "快適")
        XCTAssertEqual(Copy.causeName(.memory), "メモリ")
    }

    func testEveryShippedLanguageIsSelectableAndNamedDifferently() {
        let translated: [AppLanguage] = [.simplifiedChinese, .english, .german, .french, .japanese]
        let endonyms = translated.map(\.endonym)
        XCTAssertTrue(endonyms.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(endonyms).count, endonyms.count)

        for language in translated where language != .english {
            XCTAssertNotNil(
                Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                "\(language.rawValue).lproj 不存在"
            )
        }

        XCTAssertEqual(AppLanguage.system.endonym, AppLanguage.systemMatch.endonym)
        XCTAssertNotEqual(AppLanguage.effective, .system)
    }

    /// The Dock tile shows one word at 58 points in an 84 point column. A long
    /// translation must still render whole and stay inside the tile, so this
    /// renders the real view for every language and measures the ink.
    func testDockLabelsFitInEveryLanguage() throws {
        for language in languages {
            let copy = try table(language)
            for level in [StallLevel.fluid, .sluggish, .stalled] {
                let label = Copy.dockLevel(level, copy)
                let ink = try inkBounds(label: label)
                XCTAssertGreaterThan(ink.width, 12, "\(language) 的「\(label)」几乎没画出来")
                XCTAssertGreaterThan(ink.height, 10, "\(language) 的「\(label)」太扁，像被裁掉了")
                XCTAssertGreaterThanOrEqual(ink.minX, 6, "\(language) 的「\(label)」贴到了瓦片左边缘")
                XCTAssertLessThanOrEqual(ink.maxX, 122, "\(language) 的「\(label)」超出了瓦片右侧")
                XCTAssertGreaterThanOrEqual(ink.minY, 6, "\(language) 的「\(label)」顶到了瓦片底边")
                XCTAssertLessThanOrEqual(ink.maxY, 122, "\(language) 的「\(label)」超出了瓦片顶边")
            }
        }
    }

    private func inkBounds(label: String) throws -> CGRect {
        let assessment = StallAssessment(
            at: Date(), score: 42, level: .sluggish, stableCause: nil, causes: [], culprits: [],
            cpuBusy: 0, cpuCores: 0, memoryPressure: 0, compressorBytes: 0, swapUsedBytes: 0,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, schedulerJankMs: 0,
            thermal: .nominal, measuredCPUShare: 1
        )
        let view = DockIconView(assessment: assessment, advanced: false, label: label)
            .frame(width: DockIconView.side, height: DockIconView.side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(rep.pixelsWide) / DockIconView.side

        var left = rep.pixelsWide
        var right = -1
        var top = rep.pixelsHigh
        var bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let high = max(c.redComponent, c.greenComponent, c.blueComponent)
                let low = min(c.redComponent, c.greenComponent, c.blueComponent)
                guard c.alphaComponent > 0.5, high > 0.8, high - low < 0.15 else { continue }
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left else { return .zero }
        // CGImage row 0 is the top of the tile because the bitmap is flipped
        // relative to the SwiftUI canvas; convert to points either way.
        return CGRect(
            x: CGFloat(left) / scale,
            y: CGFloat(rep.pixelsHigh - 1 - bottom) / scale,
            width: CGFloat(right - left + 1) / scale,
            height: CGFloat(bottom - top + 1) / scale
        )
    }
}
