import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

class AppState: ObservableObject {
    // MARK: - Archive Viewing State
    @Published var selectedRARFilePath: String = ""
    @Published var statusMessage: String = NSLocalizedString("status_select", comment: "")
    @Published var archiveItems: [ArchiveItem] = []
    @Published var archiveFiles: [String] = []
    @Published var selectedFiles: Set<String> = []
    @Published var isExtracting: Bool = false
    
    // MARK: - Archive Creation State
    @Published var showArchiveCreation: Bool = false
    @Published var filesForArchiving: [SecureFile] = []
    @Published var archiveName: String = ""
    @Published var isCreatingArchive: Bool = false
    
    // MARK: - RAR Binary State
    @Published var rarBinary: SecureFile?
    @Published var canCreateArchives: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Subscribe to file load notifications
        NotificationCenter.default.publisher(for: .loadRarFilesNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let paths = notification.userInfo?["filePaths"] as? [String] {
                    self?.loadArchives(paths: paths)
                }
            }
            .store(in: &cancellables)
        
        // Check for RAR binary on launch
        checkRARBinary()
    }
    
    private let bookmarksKey = "savedBookmarks"
    private var accessedURLs: [URL] = []
    
    func openArchiveIfAccessGranted(for url: URL) {
        if hasPersistentAccess(to: url) {
            loadArchive(path: url.path)
        } else {
            requestAccessAndOpenArchive(for: url)
        }
    }
    
    private func requestAccessAndOpenArchive(for url: URL) {
        // Пытаемся получить временный доступ
        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = NSLocalizedString("temporary_access_failed", comment: "")
            return
        }
        
        // После получения временного доступа показываем диалог
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("access_request_title", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("access_request_message_format", comment: ""),
                url.lastPathComponent
            )
            alert.addButton(withTitle: NSLocalizedString("access_request_button", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))
            
            let response = alert.runModal()
            url.stopAccessingSecurityScopedResource()
            
            if response == .alertFirstButtonReturn {
                if self.saveBookmarkAndStartAccess(for: url) {
                    self.loadArchive(path: url.path)
                } else {
                    self.statusMessage = NSLocalizedString("persistent_access_failed", comment: "")
                }
            } else {
                self.statusMessage = NSLocalizedString("access_denied", comment: "")
            }
        }
    }
    
    private func hasPersistentAccess(to url: URL) -> Bool {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else {
            return false
        }
        return bookmarks[url.path] != nil
    }
    
    private func saveBookmarkAndStartAccess(for url: URL) -> Bool {
        do {
            // Получаем временный доступ для создания закладки
            guard url.startAccessingSecurityScopedResource() else {
                return false
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            // Создаем security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            // Сохраняем закладку
            var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
            
            // Начинаем постоянный доступ
            if url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
                return true
            }
            return false
        } catch {
            print(NSLocalizedString("bookmark_save_error", comment: "") + ": \(error)")
            return false
        }
    }
    
    func loadBookmarks() {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else { return }
        
        for (path, bookmarkData) in bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale {
                    // Обновляем закладку
                    _ = self.saveBookmarkAndStartAccess(for: url)
                } else if url.startAccessingSecurityScopedResource() {
                    accessedURLs.append(url)
                }
            } catch {
                print(NSLocalizedString("bookmark_load_error", comment: "") + ": \(error)")
            }
        }
    }
    
    func stopAccessingResources() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }
    
    // Проверка наличия доступа
    private func hasAccess(to url: URL) -> Bool {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else {
            return false
        }
        return bookmarks[url.path] != nil
    }
    
    // Сохранение закладки и начало доступа
    func requestPersistentAccess(to url: URL, completion: @escaping (Bool) -> Void) {
        // Проверяем, есть ли уже доступ
        if hasAccess(to: url) {
            completion(true)
            return
        }
        
        // Открываем панель для предоставления доступа
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.title = NSLocalizedString("access_request_title", comment: "")
            openPanel.message = NSLocalizedString("access_request_message", comment: "")
            openPanel.prompt = NSLocalizedString("access_request_button", comment: "")
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = false
            openPanel.directoryURL = url.deletingLastPathComponent()
            openPanel.nameFieldStringValue = url.lastPathComponent
            
            openPanel.begin { response in
                if response == .OK, let selectedURL = openPanel.url, selectedURL == url {
                    // Сохраняем закладку для постоянного доступа
                    self.saveBookmark(for: url)
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }
    
    func autoRequestAccess(for url: URL) -> Bool {
        // Проверяем, есть ли уже доступ
        if hasAccess(to: url) {
            return true
        }
        
        // Пытаемся получить доступ и сохранить закладку
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            // Сохраняем закладку
            var bookmarks = UserDefaults.standard.dictionary(forKey: "savedBookmarks") ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: "savedBookmarks")
            
            // Начинаем доступ
            return url.startAccessingSecurityScopedResource()
        } catch {
            print(NSLocalizedString("auto_access_error", comment: "") + ": \(error)")
            return false
        }
    }
    
    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
        } catch {
            print(NSLocalizedString("bookmark_save_error", comment: "") + ": \(error)")
        }
    }
    
    func requestFileAccess(completion: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("select_files", comment: "")
        openPanel.prompt = NSLocalizedString("add", comment: "")
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        
        openPanel.begin { response in
            guard response == .OK else {
                completion(nil)
                return
            }
            
            // Сохранить закладки для каждого файла
            for url in openPanel.urls {
                self.saveBookmark(for: url)
                
                // Начать доступ к ресурсу
                url.startAccessingSecurityScopedResource()
            }
            
            completion(openPanel.urls)
        }
    }
    
    // Load multiple archives (currently only the first one)
    func loadArchives(paths: [String]) {
        guard let path = paths.first else { return }
        loadArchive(path: path)
    }
    
    // Load a single archive
    func loadArchive(path: String) {
        selectedRARFilePath = path
        statusMessage = String(
            format: NSLocalizedString("loading_archive", comment: ""),
            URL(fileURLWithPath: path).lastPathComponent
        )
        listArchiveContents()
    }
    
    // List contents of the current archive
    func listArchiveContents() {
        guard !selectedRARFilePath.isEmpty else {
            statusMessage = NSLocalizedString("no_archive_path", comment: "")
            return
        }
        
        // Get path to unrar executable
        guard let unrarPath = Bundle.main.path(forResource: "unrar", ofType: nil) else {
            statusMessage = NSLocalizedString("error_unrar", comment: "")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: unrarPath)
        process.arguments = ["lb", selectedRARFilePath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: outputData, encoding: .utf8) else {
                statusMessage = NSLocalizedString("unrar_output_error", comment: "")
                return
            }
            
            var rootItems: [ArchiveItem] = []
            var pathMap: [String: ArchiveItem] = [:]
            
            let paths = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            for path in paths {
                let components = path.split(separator: "/").map(String.init)
                var currentPath = ""
                
                for (index, component) in components.enumerated() {
                    let isDirectory = index < components.count - 1
                    currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                    
                    if pathMap[currentPath] == nil {
                        let newItem = ArchiveItem(
                            name: component,
                            fullPath: currentPath,
                            isDirectory: isDirectory
                        )
                        pathMap[currentPath] = newItem
                    }
                }
            }
            
            for path in paths {
                let components = path.split(separator: "/").map(String.init)
                var currentPath = ""
                var parent: ArchiveItem? = nil
                
                for component in components {
                    currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                    guard let currentItem = pathMap[currentPath] else { continue }
                    
                    if let parent = parent {
                        if parent.children == nil {
                            parent.children = []
                        }
                        if !(parent.children?.contains(where: { $0.fullPath == currentItem.fullPath }) ?? false) {
                            parent.children?.append(currentItem)
                        }
                    } else {
                        if !rootItems.contains(where: { $0.fullPath == currentItem.fullPath }) {
                            rootItems.append(currentItem)
                        }
                    }
                    
                    parent = currentItem
                }
            }
            
            rootItems.sort { ($0.isDirectory && !$1.isDirectory) || ($0.name < $1.name) }
            
            DispatchQueue.main.async {
                self.archiveItems = rootItems
                self.archiveFiles = paths
                
                if !self.archiveItems.isEmpty {
                    self.statusMessage = String(
                        format: NSLocalizedString("status_files", comment: ""),
                        paths.count
                    )
                } else {
                    self.statusMessage = NSLocalizedString("no_files", comment: "")
                }
                
                self.selectedFiles = []
            }
            
        } catch {
            statusMessage = String(
                format: NSLocalizedString("error_general", comment: ""),
                error.localizedDescription
            )
        }
    }

    func extractFiles(_ files: [String]?) {
        guard let unrarPath = Bundle.main.path(forResource: "unrar", ofType: nil) else {
            statusMessage = NSLocalizedString("error_unrar", comment: "")
            return
        }
        
        self.isExtracting = true
        self.statusMessage = NSLocalizedString("requesting_access", comment: "")
        
        // Запрос доступа к целевой директории
        requestDirectoryAccess { [weak self] destinationURL in
            guard let self = self, let destinationURL = destinationURL else {
                self?.isExtracting = false
                self?.statusMessage = NSLocalizedString("access_denied", comment: "")
                return
            }
            
            self.statusMessage = NSLocalizedString("status_extracting", comment: "")
            
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: unrarPath)
                
                var arguments = ["x", "-o+", self.selectedRARFilePath, destinationURL.path]
                if let files = files { arguments.append(contentsOf: files) }
                process.arguments = arguments
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    DispatchQueue.main.async {
                        self.isExtracting = false
                        if process.terminationStatus == 0 {
                            self.statusMessage = NSLocalizedString("status_done", comment: "")
                            
                            // Открываем директорию в Finder
                            NSWorkspace.shared.open(destinationURL)
                        } else {
                            self.statusMessage = String(
                                format: NSLocalizedString("extraction_error", comment: ""),
                                process.terminationStatus
                            )
                        }
                        
                        // Останавливаем доступ к ресурсу
                        destinationURL.stopAccessingSecurityScopedResource()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isExtracting = false
                        self.statusMessage = String(
                            format: NSLocalizedString("error_general", comment: ""),
                            error.localizedDescription
                        )
                        destinationURL.stopAccessingSecurityScopedResource()
                    }
                }
            }
        }
    }

    // Новый метод для запроса доступа к директории
    func requestDirectoryAccess(completion: @escaping (URL?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("choose_folder", comment: "")
        openPanel.prompt = NSLocalizedString("extract_here", comment: "")
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else {
                completion(nil)
                return
            }
            
            // Сохраняем закладку для постоянного доступа
            self.saveBookmark(for: url)
            
            // Начинаем доступ к ресурсу
            if url.startAccessingSecurityScopedResource() {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }
    
    // Extract all files from archive
    func extractAll() {
        var allPaths: [String] = []
        func collectPaths(from items: [ArchiveItem]) {
            for item in items {
                allPaths.append(item.fullPath)
                if let children = item.children {
                    collectPaths(from: children)
                }
            }
        }
        collectPaths(from: archiveItems)
        extractFiles(allPaths)
    }
    
    // Extract selected files from archive
    func extractSelected() {
        extractFiles(Array(selectedFiles))
    }
    
    // Handle RAR binary selection
    func handleRARSelection(url: URL) {
        do {
            guard url.lastPathComponent == "rar" else {
                statusMessage = NSLocalizedString("select_rar_binary", comment: "")
                return
            }
            
            let secureFile = SecureFile(url: url)
            self.rarBinary = secureFile
            UserDefaults.standard.set(secureFile.bookmarkData, forKey: "rarBinaryBookmark")
            
            canCreateArchives = true
            statusMessage = NSLocalizedString("rar_binary_selected", comment: "")
        }
    }
    
    // Create a new archive
    func createArchive() {
        guard let rarFile = rarBinary else {
            statusMessage = NSLocalizedString("no_rar_binary", comment: "")
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("save_archive", comment: "")
        savePanel.nameFieldStringValue = archiveName.isEmpty ?
            NSLocalizedString("new_archive", comment: "") : archiveName
        savePanel.allowedContentTypes = [UTType(filenameExtension: "rar") ?? .archive]
        
        savePanel.begin { response in
            guard response == .OK, let archiveURL = savePanel.url else {
                self.statusMessage = NSLocalizedString("archive_creation_canceled", comment: "")
                return
            }
            
            self.isCreatingArchive = true
            self.statusMessage = NSLocalizedString("creating_archive", comment: "")
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("rar_\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    for (index, secureFile) in self.filesForArchiving.enumerated() {
                        try secureFile.accessSecurityScopedResource {
                            let destination = tempDir.appendingPathComponent(secureFile.url.lastPathComponent)
                            
                            if FileManager.default.fileExists(atPath: destination.path) {
                                try FileManager.default.removeItem(at: destination)
                            }
                            
                            try FileManager.default.copyItem(at: secureFile.url, to: destination)
                        }
                    }
                    
                    let fileNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                    var arguments = ["a", archiveURL.path]
                    arguments.append(contentsOf: fileNames)
                    
                    var processOutput = ""
                    
                    try rarFile.accessSecurityScopedResource {
                        let process = Process()
                        process.executableURL = rarFile.url
                        process.arguments = arguments
                        process.currentDirectoryURL = tempDir
                        
                        let outputPipe = Pipe()
                        process.standardOutput = outputPipe
                        process.standardError = outputPipe
                        
                        try process.run()
                        process.waitUntilExit()
                        
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        processOutput = String(data: outputData, encoding: .utf8) ?? ""
                    }
                    
                    try FileManager.default.removeItem(at: tempDir)
                    
                    DispatchQueue.main.async {
                        self.isCreatingArchive = false
                        self.statusMessage = processOutput
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isCreatingArchive = false
                        self.statusMessage = String(
                            format: NSLocalizedString("error_general", comment: ""),
                            error.localizedDescription
                        )
                    }
                }
            }
        }
    }
    
    // Check for existing RAR binary
    func checkRARBinary() {
        if let bookmarkData = UserDefaults.standard.data(forKey: "rarBinaryBookmark") {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale {
                    let secureFile = SecureFile(url: url)
                    UserDefaults.standard.set(secureFile.bookmarkData, forKey: "rarBinaryBookmark")
                    self.rarBinary = secureFile
                } else {
                    self.rarBinary = SecureFile(url: url)
                }
                
                canCreateArchives = true
            } catch {
                statusMessage = String(
                    format: NSLocalizedString("rar_restore_error", comment: ""),
                    error.localizedDescription
                )
            }
        }
    }
}

// AppState.swift
extension AppState {
    func requestAccessConfirmation(for url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("access_request_title", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("access_request_message_format", comment: ""),
                url.lastPathComponent
            )
            alert.addButton(withTitle: NSLocalizedString("access_request_button", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Пользователь разрешил доступ
                self.saveBookmark(for: url)
                if url.startAccessingSecurityScopedResource() {
                    completion(true)
                } else {
                    completion(false)
                }
            } else {
                completion(false)
            }
        }
    }
}
