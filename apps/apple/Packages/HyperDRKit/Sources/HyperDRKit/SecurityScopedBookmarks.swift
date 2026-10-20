import Foundation

/// iOS bookmarks retain the document-provider URL; unlike macOS their option
/// set has no withSecurityScope bit. Both platforms still balance URL leases.
enum SecurityScopedBookmarks {
    static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
    static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope, .withoutUI]
        #else
        []
        #endif
    }
}
