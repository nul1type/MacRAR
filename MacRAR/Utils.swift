// Utils.swift
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Secure File Wrapper
class SecureFile: NSObject, Identifiable, ObservableObject, NSCoding {
    let id = UUID()
    let url: URL
    let bookmarkData: Data?
    
    init(url: URL) {
        self.url = url
        self.bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        super.init()
    }
    
    required init?(coder: NSCoder) {
        guard let url = coder.decodeObject(forKey: "url") as? URL,
              let bookmarkData = coder.decodeObject(forKey: "bookmarkData") as? Data else {
            return nil
        }
        self.url = url
        self.bookmarkData = bookmarkData
    }
    
    func encode(with coder: NSCoder) {
        coder.encode(url, forKey: "url")
        coder.encode(bookmarkData, forKey: "bookmarkData")
    }
    
    func accessSecurityScopedResource(_ block: () throws -> Void) rethrows {
            guard let bookmarkData = bookmarkData else { return }
            
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return }
            
            if !url.startAccessingSecurityScopedResource() {
                print("Не удалось получить доступ к ресурсу")
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            try block()
        }
    
    private var accessCount = 0
        
        func beginAccess() -> Bool {
            if accessCount == 0 {
                guard url.startAccessingSecurityScopedResource() else {
                    return false
                }
            }
            accessCount += 1
            return true
        }
        
        func endAccess() {
            accessCount -= 1
            if accessCount == 0 {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        func accessSecurityScopedResource<T>(_ block: () throws -> T) rethrows -> T {
            beginAccess()
            defer { endAccess() }
            return try block()
        }
}

// Убрано явное соответствие Equatable, так как оно уже реализовано через ==
extension SecureFile {
    static func == (lhs: SecureFile, rhs: SecureFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Archive Tree View
struct ArchiveTreeView: View {
    @Binding var selectedFiles: Set<String>
    @Binding var hoveredFile: String?
    let items: [ArchiveItem]
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    ArchiveItemView(
                        item: item,
                        selectedFiles: $selectedFiles,
                        hoveredFile: $hoveredFile
                    )
                }
            }
            .padding(8)
        }
    }
}

struct ArchiveItemView: View {
    @ObservedObject var item: ArchiveItem
    @Binding var selectedFiles: Set<String>
    @Binding var hoveredFile: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(item.isDirectory ? .yellow : .secondary)
                
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !item.isDirectory {
                            if selectedFiles.contains(item.fullPath) {
                                selectedFiles.remove(item.fullPath)
                            } else {
                                selectedFiles.insert(item.fullPath)
                            }
                        }
                    }
                    .onHover { hovering in
                        hoveredFile = hovering ? item.fullPath : nil
                    }
                
                if !item.isDirectory {
                    Spacer()
                    
                    if selectedFiles.contains(item.fullPath) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                (hoveredFile == item.fullPath ? Color.blue.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
            )
            
            if item.isExpanded, let children = item.children {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(children) { child in
                        ArchiveItemView(
                            item: child,
                            selectedFiles: $selectedFiles,
                            hoveredFile: $hoveredFile
                        )
                    }
                }
                .padding(.leading, 16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                withAnimation {
                    item.isExpanded.toggle()
                }
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button(action: {
                    if selectedFiles.contains(item.fullPath) {
                        selectedFiles.remove(item.fullPath)
                    } else {
                        selectedFiles.insert(item.fullPath)
                    }
                }) {
                    Text(selectedFiles.contains(item.fullPath) ?
                         NSLocalizedString("deselect", comment: "") :
                         NSLocalizedString("select", comment: ""))
                    Image(systemName: selectedFiles.contains(item.fullPath) ?
                          "minus.circle" : "checkmark.circle")
                }
            }
        }
    }
}

// MARK: - File Operations
struct FileOperations {
    static func removeQuarantineAttribute(from url: URL) {
        let process = Process()
        process.launchPath = "/usr/bin/xattr"
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.launch()
        process.waitUntilExit()
    }
    
    static func fileIcon(for url: URL) -> String {
        if url.hasDirectoryPath { return "folder.fill" }
        
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic": return "photo.fill"
        case "pdf": return "doc.richtext.fill"
        case "txt", "rtf": return "doc.text.fill"
        case "mp3", "wav", "aac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "doc", "docx": return "doc.fill"
        case "xls", "xlsx": return "chart.bar.doc.horizontal.fill"
        case "ppt", "pptx": return "rectangle.3.group.fill"
        default: return "doc.fill"
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let loadRarFilesNotification = Notification.Name("LoadRarFilesNotification")
}

// MARK: - Localization Helpers
struct LocalizedString {
    static func get(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
    
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}

// MARK: - Safe Collection Access
extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
