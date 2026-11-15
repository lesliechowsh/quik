import AppKit
import XCTest

final class AppIconTests: XCTestCase {
    func testBundleShipsAnIcon() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "Quik")
        let icons = try XCTUnwrap(bundle.url(forResource: "Quik", withExtension: "icns"))
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: icons.path)[.size] as? Int ?? 0,
            10_000, "icns 太小，不像包含 16 到 1024 的全部尺寸"
        )
    }

    /// Reads the bundled icns rather than asking LaunchServices, which wedges
    /// on this machine. The generic document icon has a light page in the
    /// middle; the Quik tile is graphite, so a bright sample away from the
    /// white pulse means the tile never made it into the file.
    func testBundledIconIsTheGraphiteTile() throws {
        let icons = try XCTUnwrap(Bundle.main.url(forResource: "Quik", withExtension: "icns"))
        let image = try XCTUnwrap(NSImage(contentsOf: icons))
        let widths = Set(image.representations.map(\.pixelsWide)).sorted()
        XCTAssertEqual(widths, [16, 32, 64, 128, 256, 512, 1024])

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()

        let corner = try XCTUnwrap(rep.colorAt(x: 32, y: 96))
        let brightest = max(corner.redComponent, corner.greenComponent, corner.blueComponent)
        XCTAssertLessThan(brightest, 0.5, "图标中段是亮的，说明画的是系统默认图标而不是我们的瓦片")
    }
}
