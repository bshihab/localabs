import SwiftUI
import UIKit

/// Renders the LocalabsLogo's chip and heart layers as standalone
/// 1024×1024 PNGs, suitable for dragging into Apple's Icon Composer
/// as the layered assets of a `.icon` file.
///
/// This is a *development-only* tool. The "Export Logo Layers" button
/// in Profile calls `renderAllLayersToTempFiles()` and presents a
/// share sheet so the user can save the PNGs to Files / Photos /
/// AirDrop them to a Mac. Once the `.icon` is finalized and dropped
/// into the project, the export button (and this file) can be
/// removed.
@MainActor
enum LogoExportTool {

    /// Render a single layer of the logo to PNG data at 1024×1024.
    /// The logo is sized so its outer frame (chip + pins) occupies
    /// ~86% of the canvas — leaves ~7% padding on each side, which
    /// Icon Composer needs for the rounded-corner mask.
    static func renderLayer(_ layer: LocalabsLogo.Layer, canvasSize: CGFloat = 1024) -> Data? {
        // LocalabsLogo's outer frame is `s + 2 * pinH` where
        // pinH = 0.08 * s — so the frame is 1.16 * s wide. To make
        // the frame == canvas * 0.86: s = canvas * 0.86 / 1.16.
        let logoSize = canvasSize * 0.86 / 1.16

        let view = LocalabsLogo(size: logoSize, layer: layer)
            .frame(width: canvasSize, height: canvasSize)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
        renderer.proposedSize = .init(width: canvasSize, height: canvasSize)
        renderer.isOpaque = false  // transparent everywhere outside the drawn shapes
        return renderer.uiImage?.pngData()
    }

    /// Renders the three layers we'd want for Icon Composer:
    /// - `Localabs-full.png` — the entire logo, useful as a flat
    ///   PNG fallback in Assets.xcassets/AppIcon.appiconset.
    /// - `Localabs-chip.png` — chip body + pins + traces only, used
    ///   as Icon Composer's chip layer.
    /// - `Localabs-heart.png` — the white heart on transparent,
    ///   used as Icon Composer's top layer (the one that gets the
    ///   pronounced liquid-glass treatment).
    /// Returns the list of saved file URLs in the temp directory so
    /// the caller can hand them to a UIActivityViewController.
    static func renderAllLayersToTempFiles() -> [URL] {
        let outputs: [(LocalabsLogo.Layer, String)] = [
            (.full,      "Localabs-full.png"),
            (.chipOnly,  "Localabs-chip.png"),
            (.heartOnly, "Localabs-heart.png")
        ]

        var urls: [URL] = []
        for (layer, filename) in outputs {
            guard let data = renderLayer(layer) else { continue }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: url)
                urls.append(url)
            } catch {
                print("[LogoExportTool] Failed to write \(filename): \(error)")
            }
        }
        return urls
    }
}
