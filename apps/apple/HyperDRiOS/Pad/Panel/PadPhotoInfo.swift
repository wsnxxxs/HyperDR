import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The foot of the standing Studio panel: what the photo is, as a
/// photographer reads it. The camera and lens, the exposure, and the file:
/// its kind (RAW, HDR, a gain map, SDR), its size and the day it was taken.
/// Photographic notation, the same in every language.
struct PadPhotoInfo: View {
    let facts: CaptureFacts
    /// The photo's file name.
    let name: String?
    let domain: InputDomain?
    let size: (width: Int, height: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Space.s2) {
                Image(systemName: "camera")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: facts.cameraLine ?? name ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let exposure = facts.exposureLine {
                Text(verbatim: exposure)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 6) {
                if let domain {
                    kind(domain)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6)))
                }
                Text(verbatim: details)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PadMetrics.inset)
        .padding(.vertical, 12)
        .padRow()
        .accessibilityElement(children: .combine)
    }

    /// "ARW · 2768 × 1848 · 2026.09.21".
    private var details: String {
        let ext = name.map { ($0 as NSString).pathExtension.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [ext, size.map { "\($0.width) × \($0.height)" }, facts.dateLine].compactMap { $0 }
        return parts.joined(separator: CaptureFacts.separator)
    }

    private func kind(_ domain: InputDomain) -> Text {
        switch domain {
        case .rawEDR: Text(verbatim: "RAW")
        case .hdr: Text(verbatim: "HDR")
        case .dual: Text("ios.export.variant.gainMap")
        case .sdr: Text(verbatim: "SDR")
        }
    }
}
