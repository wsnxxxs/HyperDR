import SwiftUI

/// The question when a photo is opened or closed during an export (M3
/// §5.6): the user chose the file first, and only then is asked whether to
/// stop the export for it. "Keep Exporting" is the default and Esc; the
/// other button stops the export and does what was asked. The model shows no
/// question once the export has ended by itself: it just does it.
struct PhotoSwitchAlert: ViewModifier {
    let model: EditorModel

    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingPhotoSwitch, initial: true) { _, request in presented = request != nil }
            .alert(Text("switchPhoto.title \(model.document?.name ?? "")"), isPresented: $presented,
                   presenting: model.pendingPhotoSwitch) { request in
                Button("switchPhoto.keep", role: .cancel) { model.resolvePhotoSwitch(stop: false) }
                Button(LocalizedStringKey(Self.stopKey(request)), role: .destructive) { model.resolvePhotoSwitch(stop: true) }
            } message: { request in
                switch request.kind {
                case .open: Text("switchPhoto.open \(request.displayName)")
                case .close: Text("switchPhoto.close")
                }
            }
    }

    static func stopKey(_ request: PhotoSwitchRequest) -> String {
        switch request.kind {
        case .open: "switchPhoto.stopOpen"
        case .close: "switchPhoto.stopClose"
        }
    }
}

extension View {
    func photoSwitchAlert(model: EditorModel) -> some View { modifier(PhotoSwitchAlert(model: model)) }
}
