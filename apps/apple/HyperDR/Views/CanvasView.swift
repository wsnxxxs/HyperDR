import SwiftUI
import HyperDRDesign

/// The recessed workspace that will host the EDR preview. For now a gradient
/// stands in for the photograph.
struct CanvasView: View {
    var workspace: Workspace
    var viewMode: ViewMode
    var padding: CGFloat

    var body: some View {
        Group {
            switch workspace {
            case .editing: viewport
            case .empty: DropTarget()
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hdr.surfacePage)
    }

    private var viewport: some View {
        PhotoPlaceholder(viewMode: viewMode)
            .padding(Layout.canvasGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hdr.previewBackdrop, in: .rect(cornerRadius: Radius.standard))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard)
                    .strokeBorder(Color.hdr.line)
            }
    }
}

/// A 3:2 frame where the photograph will be drawn.
private struct PhotoPlaceholder: View {
    var viewMode: ViewMode

    var body: some View {
        LinearGradient(
            colors: [Color(white: 0.16), Color(white: 0.42), Color(white: 0.86)],
            startPoint: .bottomLeading, endPoint: .topTrailing)
            .overlay {
                if viewMode == .compare {
                    Rectangle().fill(Color.hdr.overlayInk).frame(width: 2)
                }
            }
            .overlay {
                Label("mac.canvas.placeholder", systemImage: "photo")
                    .font(Font.hdr.control)
                    .hdrOverlayChip()
            }
            .overlay(alignment: .topLeading) {
                if viewMode != .original {
                    HDRBadge().padding(Space.s3)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .elevation(.lg)
            .accessibilityLabel("stage.label")
    }
}

/// The empty canvas: drop a photograph here or pick one.
private struct DropTarget: View {
    var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.hdr.inkMuted)
            VStack(spacing: Space.s2) {
                Text("stage.empty")
                    .font(Font.hdr.title)
                    .foregroundStyle(Color.hdr.inkStrong)
                Text("stage.support")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Button("stage.select") {}
                .buttonStyle(.hdrPrimary)
                .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hdr.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(Color.hdr.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
    }
}
