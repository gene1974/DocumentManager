import AppKit
import Combine
import Foundation

struct FileEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedAt: Date?
    var sizeText: String

    var id: String { url.path }

    var kindText: String {
        isDirectory ? "文件夹" : "文件"
    }

    var iconName: String {
        isDirectory ? "folder.fill" : "doc.fill"
    }

    var modifiedText: String {
        guard let modifiedAt else { return "-" }
        return Self.dateFormatter.string(from: modifiedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
    enum SortField: String, CaseIterable, Identifiable {
        case name = "名称"
        case type = "类型"
        case size = "大小"
        case modifiedDate = "修改时间"

        var id: String { rawValue }
    }

    enum FileOperationError: LocalizedError {
        case editModeDisabled
        case noAuthorizedFolder
        case outsideAuthorizedFolder
        case invalidName
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .editModeDisabled:
                return "当前为只读模式，请先开启编辑模式。"
            case .noAuthorizedFolder:
                return "请先点击“选择文件夹”授权目录后再进行修改。"
            case .outsideAuthorizedFolder:
                return "仅允许修改已授权文件夹内的内容。"
            case .invalidName:
                return "文件名无效。"
            case .destinationExists:
                return "目标名称已存在，请更换名称。"
            }
        }
    }

    @Published private(set) var currentURL: URL
    @Published var pathInput: String
    @Published private(set) var rows: [FileEntry] = []
    @Published var showHiddenFiles = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            refresh()
        }
    }
    @Published var sortField: SortField = .name {
        didSet {
            guard sortField != oldValue else { return }
            applySort()
        }
    }
    @Published var sortAscending = true {
        didSet {
            guard sortAscending != oldValue else { return }
            applySort()
        }
    }
    @Published var isEditModeEnabled = false {
        didSet {
            guard isEditModeEnabled != oldValue else { return }
            handleEditModeChange()
        }
    }
    @Published var errorMessage: String?

    private var loadGeneration = 0
    private var allRows: [FileEntry] = []
    private var folderSizeCache: [URL: Int64] = [:]
    private var folderSizeTasks: [URL: Task<Void, Never>] = [:]
    private var securityScopedURL: URL?
    private var editModeTimeoutTask: Task<Void, Never>?

    init(startURL: URL? = nil) {
        let initialURL = startURL ?? Self.defaultStartURL()
        self.currentURL = initialURL
        self.pathInput = initialURL.path
        refresh()
    }

    func refresh() {
        invalidateVisibleFolderSizes()
        navigate(to: currentURL)
    }

    func navigateToPathInput() {
        let expandedPath = (pathInput as NSString).expandingTildeInPath
        let targetURL = URL(fileURLWithPath: expandedPath)
        navigate(to: targetURL)
    }

    func navigateUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent.path != currentURL.path {
            navigate(to: parent)
        }
    }

    func navigateHome() {
        if let securityScopedURL {
            navigate(to: securityScopedURL)
        } else {
            navigate(to: Self.defaultStartURL())
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择要浏览的文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let folderURL = panel.url {
            activateSecurityScope(for: folderURL)
            navigate(to: folderURL)
        }
    }

    func open(_ row: FileEntry) {
        if row.isDirectory {
            navigate(to: row.url)
            return
        }

        NSWorkspace.shared.open(row.url)
    }

    func toggleSortDirection() {
        sortAscending.toggle()
    }

    func setSortField(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
        }
    }

    func rename(_ row: FileEntry, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw FileOperationError.invalidName
        }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw FileOperationError.invalidName
        }

        let destinationURL = row.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if destinationURL.path == row.url.path {
            return
        }

        try validateWritablePath(from: row.url, to: destinationURL)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw FileOperationError.destinationExists
        }

        try FileManager.default.moveItem(at: row.url, to: destinationURL)
        resetEditModeTimeoutIfNeeded()
        refresh()
    }

    func moveToTrash(_ row: FileEntry) throws {
        try validateWritablePath(from: row.url, to: row.url)

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: row.url, resultingItemURL: &trashedURL)

        resetEditModeTimeoutIfNeeded()
        refresh()
    }

    func moveToTrash(rows: [FileEntry]) throws {
        let uniqueRows = Array(Dictionary(grouping: rows, by: \.id).values.compactMap(\.first))
        let rowsToTrash = sanitizeRowsForTrash(uniqueRows)

        for row in rowsToTrash {
            try validateWritablePath(from: row.url, to: row.url)
        }

        for row in rowsToTrash {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: row.url, resultingItemURL: &trashedURL)
        }

        resetEditModeTimeoutIfNeeded()
        refresh()
    }

    private func handleEditModeChange() {
        editModeTimeoutTask?.cancel()

        guard isEditModeEnabled else {
            return
        }

        scheduleEditModeTimeout()
    }

    private func scheduleEditModeTimeout() {
        editModeTimeoutTask?.cancel()

        editModeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.editModeDurationNanoseconds)
            guard !Task.isCancelled else { return }
            self?.disableEditModeByTimeout()
        }
    }

    private func resetEditModeTimeoutIfNeeded() {
        guard isEditModeEnabled else { return }
        scheduleEditModeTimeout()
    }

    private func disableEditModeByTimeout() {
        guard isEditModeEnabled else { return }
        isEditModeEnabled = false
//        errorMessage = "编辑模式已自动关闭，当前恢复为只读模式。"
    }

    private func invalidateVisibleFolderSizes() {
        let visibleFolderURLs = allRows.filter(\.isDirectory).map(\.url)

        for folderURL in visibleFolderURLs {
            folderSizeCache.removeValue(forKey: folderURL)
            folderSizeTasks[folderURL]?.cancel()
            folderSizeTasks[folderURL] = nil
        }
    }

    private func validateWritablePath(from sourceURL: URL, to destinationURL: URL) throws {
        guard isEditModeEnabled else {
            throw FileOperationError.editModeDisabled
        }

        guard let authorizedRoot = securityScopedURL else {
            throw FileOperationError.noAuthorizedFolder
        }

        let canonicalRoot = authorizedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDestinationParent = destinationURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()

        guard Self.isSubpath(canonicalSource, of: canonicalRoot),
              Self.isSubpath(canonicalDestinationParent, of: canonicalRoot) else {
            throw FileOperationError.outsideAuthorizedFolder
        }
    }

    private func sanitizeRowsForTrash(_ rows: [FileEntry]) -> [FileEntry] {
        let canonicalURLs = rows.map { row in
            (row, row.url.standardizedFileURL.resolvingSymlinksInPath())
        }

        return canonicalURLs.compactMap { candidate, candidateURL in
            let isCoveredByParent = canonicalURLs.contains { other, otherURL in
                guard other.id != candidate.id else { return false }
                guard other.isDirectory else { return false }
                return Self.isSubpath(candidateURL, of: otherURL)
            }

            return isCoveredByParent ? nil : candidate
        }
    }

    private nonisolated static func isSubpath(_ child: URL, of root: URL) -> Bool {
        let rootPath = root.path
        let childPath = child.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private func navigate(to url: URL) {
        let standardizedURL = url.standardizedFileURL
        loadGeneration += 1
        let generation = loadGeneration
        let showHiddenFiles = showHiddenFiles

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loadedRows = try Self.loadRows(in: standardizedURL, showHiddenFiles: showHiddenFiles)
                await self?.applyLoadedRows(loadedRows, for: standardizedURL, generation: generation)
            } catch {
                await self?.applyLoadingError(error, attemptedURL: standardizedURL, generation: generation)
            }
        }
    }

    private func applyLoadedRows(_ loadedRows: [FileEntry], for url: URL, generation: Int) {
        guard generation == loadGeneration else { return }

        currentURL = url
        pathInput = url.path
        errorMessage = nil
        allRows = loadedRows

        for (index, row) in allRows.enumerated() where row.isDirectory {
            if let cachedSize = folderSizeCache[row.url] {
                allRows[index].sizeText = Self.byteCountString(cachedSize)
            } else {
                allRows[index].sizeText = "计算中..."
                scheduleFolderSizeTask(for: row.url)
            }
        }

        applySort()
    }

    private func applyLoadingError(_ error: Error, attemptedURL: URL, generation: Int) {
        guard generation == loadGeneration else { return }

        errorMessage = "无法访问目录：\(attemptedURL.path)\n\(error.localizedDescription)\n\n提示：沙箱模式下请点击“选择文件夹”授权要访问的目录。"
    }

    private func scheduleFolderSizeTask(for folderURL: URL) {
        if folderSizeTasks[folderURL] != nil {
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            let size = Self.calculateFolderSize(at: folderURL)
            await self?.applyFolderSize(size, for: folderURL)
        }

        folderSizeTasks[folderURL] = task
    }

    private func applyFolderSize(_ size: Int64?, for folderURL: URL) {
        guard folderSizeTasks[folderURL] != nil else {
            return
        }

        folderSizeTasks[folderURL] = nil

        if let size {
            folderSizeCache[folderURL] = size
        }

        guard let index = allRows.firstIndex(where: { $0.url == folderURL }) else {
            return
        }

        allRows[index].sizeText = size.map(Self.byteCountString(_:)) ?? "读取失败"
        applySort()
    }

    private func applySort() {
        rows = allRows.sorted { lhs, rhs in
            switch sortField {
            case .name:
                return compareNames(lhs, rhs)
            case .type:
                return compareTypes(lhs, rhs)
            case .size:
                return compareSizes(lhs, rhs)
            case .modifiedDate:
                return compareModifiedDates(lhs, rhs)
            }
        }
    }

    private func compareNames(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if result == .orderedSame {
            return lhs.url.path < rhs.url.path
        }

        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compareTypes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return sortAscending ? lhs.isDirectory : !lhs.isDirectory
        }

        let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if result == .orderedSame {
            return lhs.url.path < rhs.url.path
        }

        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compareSizes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        let leftSize = sizeValue(for: lhs)
        let rightSize = sizeValue(for: rhs)

        if let leftSize, let rightSize, leftSize != rightSize {
            return sortAscending ? leftSize < rightSize : leftSize > rightSize
        }

        if leftSize == nil, rightSize != nil { return false }
        if leftSize != nil, rightSize == nil { return true }

        let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if result == .orderedSame {
            return lhs.url.path < rhs.url.path
        }

        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compareModifiedDates(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if let leftDate = lhs.modifiedAt, let rightDate = rhs.modifiedAt, leftDate != rightDate {
            return sortAscending ? leftDate < rightDate : leftDate > rightDate
        }

        if lhs.modifiedAt == nil, rhs.modifiedAt != nil { return false }
        if lhs.modifiedAt != nil, rhs.modifiedAt == nil { return true }

        let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if result == .orderedSame {
            return lhs.url.path < rhs.url.path
        }

        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func sizeValue(for entry: FileEntry) -> Int64? {
        if entry.isDirectory {
            return folderSizeCache[entry.url]
        }

        return entry.fileSize
    }

    private func activateSecurityScope(for folderURL: URL) {
        if let previous = securityScopedURL {
            previous.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }

        if folderURL.startAccessingSecurityScopedResource() {
            securityScopedURL = folderURL
        }
    }

    private nonisolated static func defaultStartURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private nonisolated static func loadRows(in directoryURL: URL, showHiddenFiles: Bool) throws -> [FileEntry] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey
        ]

        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )

        return fileURLs.map { url in
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory ?? false
            let fileSize = values?.fileSize.map(Int64.init)
            let name = values?.localizedName ?? url.lastPathComponent
            let modifiedAt = values?.contentModificationDate

            let sizeText: String
            if isDirectory {
                sizeText = "计算中..."
            } else if let fileSize {
                sizeText = byteCountString(fileSize)
            } else {
                sizeText = "-"
            }

            return FileEntry(
                url: url,
                name: name,
                isDirectory: isDirectory,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                sizeText: sizeText
            )
        }
    }

    private nonisolated static func calculateFolderSize(at folderURL: URL) -> Int64? {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else {
            return nil
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                    return
                }

                guard values.isRegularFile == true else {
                    return
                }

                let byteSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                totalSize += Int64(byteSize)
            }
        }

        return totalSize
    }

    private nonisolated static func byteCountString(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private nonisolated static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private nonisolated static let editModeDurationNanoseconds: UInt64 = 120 * 1_000_000_000
}
