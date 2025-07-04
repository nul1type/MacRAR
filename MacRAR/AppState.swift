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
    
    // Load multiple archives (currently only the first one)
    func loadArchives(paths: [String]) {
        guard let path = paths.first else { return }
        loadArchive(path: path)
    }
    
    // Load a single archive
    func loadArchive(path: String) {
        selectedRARFilePath = path
        statusMessage = String(format: NSLocalizedString("loading_archive", comment: ""), URL(fileURLWithPath: path).lastPathComponent)
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
                    self.statusMessage = String(format: NSLocalizedString("status_files", comment: ""), paths.count)
                } else {
                    self.statusMessage = NSLocalizedString("no_files", comment: "")
                }
                
                self.selectedFiles = []
            }
            
        } catch {
            statusMessage = String(format: NSLocalizedString("error_general", comment: ""), error.localizedDescription)
        }
    }
    
    // Extract files from archive
    func extractFiles(_ files: [String]?) {
        guard let unrarPath = Bundle.main.path(forResource: "unrar", ofType: nil) else {
            statusMessage = NSLocalizedString("error_unrar", comment: "")
            return
        }
        
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("choose_folder", comment: "")
        openPanel.prompt = NSLocalizedString("extract_here", comment: "")
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else {
                self.statusMessage = NSLocalizedString("extraction_canceled", comment: "")
                return
            }
            
            self.isExtracting = true
            self.statusMessage = NSLocalizedString("status_extracting", comment: "")
            
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: unrarPath)
                
                var arguments = ["x", "-o+", self.selectedRARFilePath, url.path]
                if let files = files { arguments.append(contentsOf: files) }
                process.arguments = arguments
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    DispatchQueue.main.async {
                        self.isExtracting = false
                        if process.terminationStatus == 0 {
                            self.statusMessage = NSLocalizedString("status_done", comment: "")
                            NSWorkspace.shared.open(url)
                        } else {
                            self.statusMessage = String(format: NSLocalizedString("extraction_error", comment: ""), process.terminationStatus)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isExtracting = false
                        self.statusMessage = String(format: NSLocalizedString("error_general", comment: ""), error.localizedDescription)
                    }
                }
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
                        self.statusMessage = String(format: NSLocalizedString("error_general", comment: ""), error.localizedDescription)
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
                statusMessage = String(format: NSLocalizedString("rar_restore_error", comment: ""), error.localizedDescription)
            }
        }
    }
}
