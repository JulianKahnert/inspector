import Foundation
import InspectorKit

/// Finds the Xcode workspace or project a repository builds its app from.
enum WorkspaceFinder {
  /// The one `.xcworkspace` in `root` or up to three levels below it, else the one `.xcodeproj`;
  /// a workspace wins because it holds the project and its packages.
  ///
  /// - Throws: ``ErrorCode/badRequest`` when there is none, or several of the winning kind.
  static func find(in root: URL) throws(InspectorError) -> URL {
    var workspaces: [URL] = []
    var projects: [URL] = []
    var level = [root]
    for _ in 0..<4 {
      var next: [URL] = []
      for directory in level {
        for entry in children(of: directory) {
          switch entry.pathExtension {
          case "xcworkspace": workspaces.append(entry)
          case "xcodeproj": projects.append(entry)
          default:
            // Build output and dependencies carry projects of their own.
            if !skipped.contains(entry.lastPathComponent) { next.append(entry) }
          }
        }
      }
      level = next
    }
    let candidates = workspaces.isEmpty ? projects : workspaces
    guard candidates.count == 1, let found = candidates.first else {
      let names = candidates.map { $0.path(percentEncoded: false) }.sorted()
      throw InspectorError(
        code: .badRequest,
        message: names.isEmpty
          ? "no Xcode workspace or project in `\(root.path)`; pass `--workspace <path>`"
          : "several Xcode workspaces or projects in `\(root.path)`; pass `--workspace <path>`",
        detail: names.isEmpty ? nil : names.joined(separator: "\n"))
    }
    return found
  }

  private static let skipped: Set = ["Pods", "Carthage", "DerivedData", "node_modules", "build"]

  /// The visible subdirectories of `directory`.
  private static func children(of directory: URL) -> [URL] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
  }
}
