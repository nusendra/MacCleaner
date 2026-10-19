import Foundation

/// Old autosaved revisions of Pages, Numbers, Keynote and Sketch documents.
struct DocumentVersionsScanTask: JunkScanTask {
    let identifier = "documentVersions"
    let title = "Document versions"
    let group = JunkGroupID.documentVersions
    var timeout: Duration { .seconds(300) }

    /// Versions closer than this to the next newer one are treated as an autosave burst.
    static let burstInterval: TimeInterval = 4 * 60 * 60

    private static let documentTypes: [(app: String, bundleID: String, uti: String)] = [
        ("Sketch", "com.bohemiancoding.sketch3", "com.bohemiancoding.sketch.drawing.single"),
        ("Pages", "com.apple.iwork.pages", "com.apple.iwork.pages.sffpages"),
        ("Keynote", "com.apple.iwork.keynote", "com.apple.iwork.keynote.sffkey"),
        ("Numbers", "com.apple.iwork.numbers", "com.apple.iwork.numbers.numbers"),
    ]

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        try Self.documentTypes.compactMap { type -> JunkSubgroup? in
            guard !context.ignore.isIgnored(name: type.bundleID) else { return nil }
            let output = try ProcessRunner.run("/usr/bin/mdfind", ["kMDItemContentType == '\(type.uti)'"], timeout: 120)
            let documents = String(decoding: output.stdout, as: UTF8.self)
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
                .filter { !$0.path.contains("/Dropbox/") && !context.ignore.isIgnored($0) }

            var items: [JunkItem] = []
            for document in documents {
                try Task.checkCancellation()
                items += versionItems(for: document, context)
            }
            return items.isEmpty ? nil : JunkSubgroup(id: "versions.\(type.bundleID)", title: type.app, bundleIdentifier: type.bundleID, items: items)
        }
    }

    private func versionItems(for document: URL, _ context: ScanContext) -> [JunkItem] {
        let versions = (NSFileVersion.otherVersionsOfItem(at: document) ?? [])
            .compactMap { version -> (date: Date, size: Int64)? in
                guard let date = version.modificationDate else { return nil }
                let size = context.size(of: version.url)
                return size > 0 ? (date, size) : nil
            }
            .sorted { $0.date > $1.date }
        let selected = Self.selection(for: versions.map(\.date))

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return versions.enumerated().map { index, version in
            JunkItem(
                id: "\(document.path)#\(version.date.timeIntervalSinceReferenceDate)",
                name: document.lastPathComponent,
                detail: formatter.string(from: version.date),
                url: document,
                size: version.size,
                isAutoSelected: selected.contains(index),
                action: .removeFileVersion(document: document, modificationDate: version.date)
            )
        }
    }

    /// Dates sorted newest first. Never preselect the newest or oldest; preselect a middle version
    /// when it lies within `burstInterval` of the next newer one.
    static func selection(for dates: [Date]) -> Set<Int> {
        guard dates.count > 2 else { return [] }
        return Set((1..<(dates.count - 1)).filter { abs(dates[$0].timeIntervalSince(dates[$0 - 1])) < burstInterval })
    }
}
