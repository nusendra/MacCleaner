import Darwin
import Foundation

private func trashItems(in folder: URL, _ context: ScanContext) -> [JunkItem] {
    context.children(of: folder, includeHidden: true).compactMap { url in
        guard context.canRemove(url) else { return nil }
        return JunkItem(name: url.lastPathComponent, url: url, size: context.size(of: url), isAutoSelected: true, action: .delete(url))
    }
}

/// ~/.Trash and iCloud Drive trashes.
struct TrashesScanTask: JunkScanTask {
    let identifier = "trashes"
    let title = "Trash"
    let group = JunkGroupID.trashes

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let home = context.paths.home
        var subgroups: [JunkSubgroup] = []
        let system = trashItems(in: home.appending(path: ".Trash"), context)
        if !system.isEmpty { subgroups.append(JunkSubgroup(id: "trash.system", title: "Trash", items: system)) }

        let mobileDocuments = context.paths.library.appending(path: "Mobile Documents")
        var cloudFolders = [
            mobileDocuments.appending(path: ".Trash"),
            mobileDocuments.appending(path: "com~apple~CloudDocs/.Trash"),
            context.paths.library.appending(path: "CloudStorage/iCloud Drive/.Trash"),
        ]
        cloudFolders += context.children(of: mobileDocuments).map { $0.appending(path: "Documents/.Trash") }
        let cloud = cloudFolders.filter(context.exists).flatMap { trashItems(in: $0, context) }
        if !cloud.isEmpty { subgroups.append(JunkSubgroup(id: "trash.icloud", title: "iCloud Drive Trash", items: cloud)) }
        return subgroups
    }
}

/// `/Volumes/<name>/.Trashes/<uid>` on local, writable, browsable volumes.
struct MountedTrashesScanTask: JunkScanTask {
    let identifier = "mountedTrashes"
    let title = "External drive trashes"
    let group = JunkGroupID.trashes

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard volume.path.lowercased().hasPrefix("/volumes/"),
                  let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true, values.volumeIsLocal == true, values.volumeIsReadOnly != true
            else { return nil }
            let items = trashItems(in: volume.appending(path: ".Trashes/\(getuid())"), context)
            return items.isEmpty ? nil : JunkSubgroup(id: "trash.\(volume.path)", title: "Trash on \(values.volumeName ?? volume.lastPathComponent)", items: items)
        }
    }
}
