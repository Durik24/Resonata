import AppKit
import CoreImage
import SwiftUI

/// Pulls a usable accent colour out of album art.
enum ArtworkAccent {

    /// Colour-managed on purpose. The previous context disabled management
    /// (`workingColorSpace: NSNull()`), which reads a wide-gamut cover's raw
    /// numbers as if they were sRGB and shifts every colour in it.
    private static let context = CIContext()

    /// 32x32 = 1024 samples. Coarser grids blend neighbouring colours into
    /// intermediates that aren't in the artwork at all.
    private static let grid = 32

    static func color(from url: URL?) async -> Color? {
        guard let url, let data = await load(url), let image = CIImage(data: data),
              let pixels = downsample(image) else { return nil }
        return dominantColour(in: pixels)
    }

    private static func downsample(_ image: CIImage) -> [UInt8]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(grid) / extent.width,
            y: CGFloat(grid) / extent.height
        ))

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var buffer = [UInt8](repeating: 0, count: grid * grid * 4)
        context.render(
            scaled,
            toBitmap: &buffer,
            rowBytes: grid * 4,
            bounds: CGRect(x: 0, y: 0, width: grid, height: grid),
            format: .RGBA8,
            colorSpace: srgb
        )
        return buffer
    }

    /// Picks the colour the artwork is actually *about*, rather than averaging
    /// it.
    ///
    /// Averaging was the old approach and it's wrong in a specific way: mix all
    /// the pixels of any busy cover and you land on grey-brown every time, so
    /// the saturation then had to be forced back up, which invented a hue that
    /// wasn't in the image. Monochrome covers came out tinted at random.
    ///
    /// Instead, pixels vote for a bin weighted by how colourful they are, so a
    /// small vivid area beats a large muddy one, and the winner is reported as
    /// the average of the actual pixels that landed in it. Nothing is
    /// reconstructed from clamped hue/saturation numbers, so the result is a
    /// colour that genuinely appears in the artwork.
    ///
    /// Pixels with no usable hue — near-black, near-white, near-grey — abstain.
    /// If they all abstain the cover really has no colour (a black-and-white
    /// sleeve, say) and this returns nil so the panel stays black, rather than
    /// inventing a tint.
    private static func dominantColour(in pixels: [UInt8]) -> Color? {
        struct Bin {
            var weight = 0.0
            var r = 0.0, g = 0.0, b = 0.0
        }

        // Binned by hue *and* by lightness: without the second axis a dark
        // burgundy and a bright pink land together and average into neither.
        let hueBins = 24, levelBins = 3
        var bins = [Bin](repeating: Bin(), count: hueBins * levelBins)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            let high = max(r, g, b), low = min(r, g, b)
            let chroma = high - low
            let saturation = high <= 0 ? 0 : chroma / high
            guard saturation > 0.15, high > 0.12, high < 0.98 else { continue }

            var hue: Double
            if high == r        { hue = (g - b) / chroma / 6 }
            else if high == g   { hue = ((b - r) / chroma + 2) / 6 }
            else                { hue = ((r - g) / chroma + 4) / 6 }
            if hue < 0 { hue += 1 }

            let level = min(levelBins - 1, Int(high * Double(levelBins)))
            let index = min(hueBins - 1, Int(hue * Double(hueBins))) * levelBins + level
            let weight = saturation * high

            bins[index].weight += weight
            bins[index].r += r * weight
            bins[index].g += g * weight
            bins[index].b += b * weight
        }

        // Roughly "at least a few strongly coloured samples out of 1024".
        guard let best = bins.max(by: { $0.weight < $1.weight }), best.weight > 1.5 else {
            return nil
        }

        var r = best.r / best.weight
        var g = best.g / best.weight
        var b = best.b / best.weight

        // The only correction applied, and it's proportional: a colour too dark
        // to register against a black panel is scaled up along its own RGB
        // ratios. That preserves the hue exactly — the old code re-derived the
        // colour from clamped values instead, which shifted it.
        let peak = max(r, g, b)
        if peak > 0, peak < 0.55 {
            let lift = 0.55 / peak
            r = min(1, r * lift)
            g = min(1, g * lift)
            b = min(1, b * lift)
        }

        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private static func load(_ url: URL) async -> Data? {
        // Music's artwork is a file we wrote ourselves; Spotify's is remote.
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? await URLSession.shared.data(from: url).0
    }
}
