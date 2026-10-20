import Foundation

// iOS document bookmarks have no withSecurityScope option. Both platforms
// still balance URL leases, and resolution must not present system UI.
#if os(macOS)
let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
#else
let bookmarkResolution: URL.BookmarkResolutionOptions = [.withoutUI]
let bookmarkCreation: URL.BookmarkCreationOptions = []
#endif
