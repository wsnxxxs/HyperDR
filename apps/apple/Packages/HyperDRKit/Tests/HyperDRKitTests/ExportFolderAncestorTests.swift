import Darwin
import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

struct ExportFolderAncestorTests {
    @Test func ancestorLookupDenialFailsClosedAndUsesOnlySelectedFD() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        for denial in [EPERM, EACCES] {
            var paths: [String] = []
            do {
                try ExportTarget.validateFolderAncestors(descriptor, excluding: [], readAncestor: { fd, path, info in
                    #expect(fd == descriptor)
                    paths.append(path)
                    if paths.count == 2 { errno = denial; return -1 }
                    return fstatat(fd, path, &info, 0)
                })
                Issue.record("An incomplete identity walk must be rejected")
            } catch {
                #expect((error as? HyperDRError)?.code == "export_folder_unwritable")
            }
            #expect(paths == ["..", "../.."])
        }
    }

    @Test func identityExclusionRejectsWorkspaceAliasAndDescendants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace"), child = workspace.appendingPathComponent("nested/child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        let descriptor = open(child.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        do {
            try ExportTarget.validateFolderAncestors(descriptor, excluding: [alias])
            Issue.record("An alias for the workspace must be rejected by identity")
        } catch { #expect((error as? HyperDRError)?.code == "export_folder_inside_workspace") }
        try ExportTarget.validateFolderAncestors(descriptor, excluding: [root.appendingPathComponent("absent")])
    }
}
