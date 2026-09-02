import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR code for the pairing link.
///
/// Kept light-on-dark inverted *only* in its frame, never in the code itself —
/// phone cameras read dark modules on a light field far more reliably, and the
/// whole point of this panel is that a phone reads it on the first try.
struct QRCode: View {
    let text: String
    let side: CGFloat

    var body: some View {
        if let img = Self.image(for: text) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .padding(6)
                .background(Color.white)
        } else {
            Rectangle()
                .fill(Theme.panel)
                .frame(width: side, height: side)
                .overlay(Text("NO QR").font(Theme.mono(9)).foregroundStyle(Theme.textGhost))
        }
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    private static let ciContext = CIContext()

    static func image(for text: String) -> NSImage? {
        if let hit = cache[text] { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }

        // Scale by an integer factor so modules stay pixel-crisp.
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width,
                                                    height: scaled.extent.height))
        cache[text] = img
        return img
    }
}

/// Pairing sheet: scan, or copy the link.
struct CastPanel: View {
    @ObservedObject private var cast = Broadcast.shared
    let k: CGFloat
    let accent: Color
    let onClose: () -> Void

    @StateObject private var copied = CopyFlash()

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * k) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * k) {
                Text("BROADCAST")
                    .font(Theme.mono(13 * k, .black))
                    .tracking(3 * k)
                    .foregroundStyle(Theme.textBright)
                Text(cast.status)
                    .font(Theme.mono(8.5 * k, .bold))
                    .tracking(1.6)
                    .foregroundStyle(cast.isOn ? Theme.lime : Theme.textGhost)
                Spacer()
                Button(action: onClose) {
                    Text("✕")
                        .font(Theme.mono(12 * k, .bold))
                        .foregroundStyle(Theme.textGhost)
                        .padding(4 * k)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noDrag()
            }

            if cast.isOn {
                HStack(alignment: .top, spacing: 12 * k) {
                    QRCode(text: cast.url, side: 108 * k)

                    VStack(alignment: .leading, spacing: 7 * k) {
                        field("PHONE / TABLET", cast.url)
                        field("APPLE WATCH", cast.watchURL)

                        HStack(spacing: 6 * k) {
                            SectionButton(title: copied.flash == 1 ? "COPIED" : "COPY LINK",
                                          accent: accent, k: k) {
                                copy(cast.url, 1)
                            }
                            SectionButton(title: copied.flash == 2 ? "COPIED" : "COPY WATCH",
                                          accent: Theme.textDim, k: k) {
                                copy(cast.watchURL, 2)
                            }
                        }

                        Text("\(cast.clients) DEVICE\(cast.clients == 1 ? "" : "S") STREAMING")
                            .font(Theme.mono(8 * k, .bold))
                            .tracking(1.4)
                            .foregroundStyle(cast.clients > 0 ? Theme.lime : Theme.textGhost)
                    }
                }

                Text("SCAN → SAFARI/CHROME → SHARE → ADD TO HOME SCREEN.\nWATCH: SHORTCUTS → GET CONTENTS OF URL → SHOW RESULT.")
                    .font(Theme.mono(7.5 * k, .medium))
                    .tracking(0.9)
                    .lineSpacing(2 * k)
                    .foregroundStyle(Theme.textGhost)
            } else {
                Text("SERVES THIS MAC'S TELEMETRY TO YOUR PHONE, TABLET AND WATCH\nOVER LOCAL WI-FI. THE LINK CARRIES A KEY; NOTHING LEAVES THE LAN.")
                    .font(Theme.mono(8 * k, .medium))
                    .tracking(0.9)
                    .lineSpacing(3 * k)
                    .foregroundStyle(Theme.textDim)
            }

            HStack(spacing: 8 * k) {
                SectionButton(title: cast.isOn ? "STOP BROADCAST" : "START BROADCAST",
                              accent: cast.isOn ? Theme.danger : Theme.lime, k: k) {
                    cast.toggle()
                }
                Spacer()
                if cast.isOn {
                    Text("PORT \(cast.boundPort)")
                        .font(Theme.mono(8 * k, .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textGhost)
                }
            }
        }
        .padding(14 * k)
        .frame(width: 340 * k)
        .background(Theme.void.opacity(0.97))
        .overlay(Rectangle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
        .overlay(CornerBrackets(color: accent, k: k))
        .noDrag()
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            Text(label)
                .font(Theme.mono(7.5 * k, .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.textGhost)
            Text(value)
                .font(Theme.mono(9 * k, .bold))
                .foregroundStyle(Theme.textBright)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ s: String, _ which: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied.show(which)
    }
}

/// Two seconds of "COPIED", then back. A tiny object so the flash doesn't
/// re-render the whole HUD.
final class CopyFlash: ObservableObject {
    @Published var flash = 0
    private var work: DispatchWorkItem?

    func show(_ which: Int) {
        flash = which
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flash = 0 }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

/// Flat HUD-styled button.
struct SectionButton: View {
    let title: String
    let accent: Color
    let k: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(8.5 * k, .bold))
                .tracking(1.5)
                .foregroundStyle(accent)
                .padding(.vertical, 5 * k)
                .padding(.horizontal, 9 * k)
                .background(accent.opacity(0.12))
                .overlay(Rectangle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noDrag()
    }
}
