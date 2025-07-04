// ContentView.swift
import SwiftUI
import UniformTypeIdentifiers

enum PickerType {
    case rarFile
    case rarBinary
}

class ArchiveItem: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let fullPath: String
    let isDirectory: Bool
    var children: [ArchiveItem]?
    @Published var isExpanded = false
    
    init(name: String, fullPath: String, isDirectory: Bool, children: [ArchiveItem]? = nil) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.children = children
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    // Состояния для управления UI
    @State private var isDropTargeted = false
    @State private var activePicker: PickerType?
    @State private var lastActivePicker: PickerType?
    @State private var searchText = ""
    @State private var hoveredFile: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                
                VStack(spacing: 0) {
                    if appState.archiveFiles.isEmpty {
                        emptyStateView
                    } else {
                        toolbarSection
                        fileListView
                    }
                    
                    statusSection
                }
            }
            .frame(minWidth: 700, minHeight: 500)
            .navigationTitle("MacRAR")
            .fileImporter(
                isPresented: Binding(
                    get: { activePicker != nil },
                    set: { newValue in
                        if !newValue {
                            lastActivePicker = activePicker
                            activePicker = nil
                        }
                    }
                ),
                allowedContentTypes: activePicker == .rarFile ? [UTType(filenameExtension: "rar")!] : [.unixExecutable],
                allowsMultipleSelection: false
            ) { result in
                switch lastActivePicker {
                case .rarFile:
                    if case .success(let urls) = result, let url = urls.first {
                        appState.openArchiveIfAccessGranted(for: url)
                    }
                case .rarBinary:
                    handleRARSelection(result)
                case nil:
                    break
                }
                lastActivePicker = nil
            }
            .onAppear {
                appState.checkRARBinary()
                appState.statusMessage = NSLocalizedString("status_select", comment: "")
            }
            .sheet(isPresented: $appState.showArchiveCreation) {
                archiveCreationView
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                return handleDroppedArchive(providers: providers)
            }
        }
        .accentColor(.blue)
        .preferredColorScheme(.dark)
    }
    
    // MARK: - UI Components
    private var toolbarSection: some View {
        HStack(spacing: 16) {
            Button(action: { activePicker = .rarFile }) {
                Label(NSLocalizedString("select_rar", comment: ""), systemImage: "folder")
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.liquidGlass)
            
            if !appState.archiveFiles.isEmpty {
                Spacer()
                
                Button(action: appState.extractAll) {
                    Label(NSLocalizedString("extract_all", comment: ""), systemImage: "archivebox")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.liquidGlassProminent)
                .disabled(appState.isExtracting)
                
                Button(action: appState.extractSelected) {
                    Label(NSLocalizedString("extract_selected", comment: ""), systemImage: "doc.zipper")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.liquidGlassProminent)
                .disabled(appState.isExtracting || appState.selectedFiles.isEmpty)
            }
            
            if appState.canCreateArchives {
                Button(action: { appState.showArchiveCreation = true }) {
                    Label(NSLocalizedString("create_archive", comment: ""), systemImage: "plus")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.liquidGlass)
            } else {
                Button(action: { activePicker = .rarBinary }) {
                    Label(NSLocalizedString("select_rar_binary", comment: ""), systemImage: "terminal")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.liquidGlass)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "archivebox")
                .font(.system(size: 72))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            
            VStack(spacing: 8) {
                Text("MacRAR Beta - GUI for UnRAR & RAR")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                
                Text(NSLocalizedString("status_select", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if !appState.canCreateArchives {
                    VStack(spacing: 12) {
                        Text(NSLocalizedString("need_rar_binary", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 16)
                }
            }
            toolbarSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var fileListView: some View {
        VStack(spacing: 0) {
            Text(URL(fileURLWithPath: appState.selectedRARFilePath).lastPathComponent)
                .font(.headline)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .padding(.horizontal)
            
            HStack {
                LiquidGlassTextField(text: $searchText, placeholder: NSLocalizedString("search", comment: ""))
                    .frame(maxWidth: .infinity)
                
                Button(action: toggleSelectAll) {
                    Text(appState.selectedFiles.isEmpty ?
                         NSLocalizedString("select_all", comment: "") :
                         NSLocalizedString("deselect_all", comment: ""))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.liquidGlass)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            ArchiveTreeView(
                selectedFiles: $appState.selectedFiles,
                hoveredFile: $hoveredFile,
                items: appState.archiveItems
            )
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
    
    private var statusSection: some View {
        HStack(alignment: .top, spacing: 8) {
            if appState.isExtracting || appState.isCreatingArchive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding(.top, 4)
            }
            
            ScrollView(.horizontal, showsIndicators: true) {
                Text(appState.statusMessage)
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 40)
            
            Spacer()
            
            Button(action: copyStatusToClipboard) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .padding(6)
                    .background(Circle().fill(Color.gray.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("copy_status", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(NSLocalizedString("copy_status", comment: "")) {
                copyStatusToClipboard()
            }
        }
    }
    
    private var archiveCreationView: some View {
        VStack(spacing: 16) {
            HStack {
                Text(NSLocalizedString("create_archive_title", comment: ""))
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: {
                    appState.showArchiveCreation = false
                    appState.filesForArchiving.removeAll()
                    appState.archiveName = ""
                    isDropTargeted = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NSLocalizedString("archive_name", comment: ""))
                            .font(.headline)
                            .frame(width: 100, alignment: .leading)
                        
                        TextField(NSLocalizedString("new_archive", comment: ""), text: $appState.archiveName)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.windowBackgroundColor))
                            )
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: addFilesForArchive) {
                            Label(NSLocalizedString("add_files", comment: ""), systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.liquidGlass)
                        
                        Button(action: addFolderForArchive) {
                            Label(NSLocalizedString("add_folder", comment: ""), systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.liquidGlass)
                        
                        Button(NSLocalizedString("clear", comment: "")) {
                            appState.filesForArchiving.removeAll()
                        }
                        .buttonStyle(.liquidGlass)
                        .disabled(appState.filesForArchiving.isEmpty)
                        .frame(width: 100)
                    }
                    .frame(maxWidth: .infinity)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDropTargeted ? Color.blue.opacity(0.1) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        isDropTargeted ? Color.blue : Color.gray.opacity(0.5),
                                        style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 1, dash: [6])
                                    )
                            )
                            .frame(minHeight: 200)
                        
                        if appState.filesForArchiving.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray.and.arrow.down")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                
                                Text(NSLocalizedString("drop_files_here", comment: ""))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(appState.filesForArchiving) { secureFile in
                                        HStack {
                                            Image(systemName: fileIcon(for: secureFile.url))
                                                .frame(width: 24)
                                            
                                            VStack(alignment: .leading) {
                                                Text(secureFile.url.lastPathComponent)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                
                                                Text(secureFile.url.deletingLastPathComponent().path)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            
                                            Spacer()
                                            
                                            Button(action: {
                                                if let index = appState.filesForArchiving.firstIndex(of: secureFile) {
                                                    appState.filesForArchiving.remove(at: index)
                                                }
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        }
                    }
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDroppedFiles(providers: providers)
                        return true
                    }
                }
                .padding(.horizontal)
            }
            
            Button(action: appState.createArchive) {
                if appState.isCreatingArchive {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(8)
                } else {
                    Text(NSLocalizedString("create_archive", comment: ""))
                        .font(.headline)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.liquidGlassProminent)
            .disabled(appState.filesForArchiving.isEmpty || appState.archiveName.isEmpty || appState.isCreatingArchive)
            .padding(.bottom, 12)
        }
        .padding()
        .frame(width: 600, height: 600)
        .background(LiquidGlassBackground())
    }
    
    // MARK: - Функции
    private func handleDroppedArchive(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            if let url = url, url.pathExtension.lowercased() == "rar" {
                DispatchQueue.main.async {
                    appState.loadArchive(path: url.path)
                }
            }
        }
        
        return true
    }
    
    private func copyStatusToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(appState.statusMessage, forType: .string)
        
        let originalMessage = appState.statusMessage
        appState.statusMessage = NSLocalizedString("copied_to_clipboard", comment: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            appState.statusMessage = originalMessage
        }
    }
    
    private func toggleSelectAll() {
        if appState.selectedFiles.count > 0 {
            appState.selectedFiles = []
        } else {
            appState.selectedFiles = Set(appState.archiveFiles)
        }
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
            if case .success(let urls) = result, let url = urls.first {
                // Запрос постоянного доступа к файлу
                appState.requestPersistentAccess(to: url) { granted in
                    if granted {
                        DispatchQueue.main.async {
                            appState.loadArchive(path: url.path)
                        }
                    } else {
                        appState.statusMessage = NSLocalizedString("access_denied", comment: "")
                    }
                }
            }
        }

    private func handleRARSelection(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            appState.handleRARSelection(url: url)
        } else if case .failure(let error) = result {
            appState.statusMessage = String(format: NSLocalizedString("file_selection_error", comment: ""), error.localizedDescription)
        }
    }
    
    private func handleDroppedFiles(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var newFiles: [SecureFile] = []
        
        for provider in providers {
            group.enter()
            
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                defer { group.leave() }
                
                if let url = url {
                    if !appState.filesForArchiving.contains(where: { $0.url == url }) {
                        newFiles.append(SecureFile(url: url))
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            if !newFiles.isEmpty {
                appState.filesForArchiving.append(contentsOf: newFiles)
                appState.statusMessage = String(format: NSLocalizedString("files_added", comment: ""), newFiles.count)
            }
            isDropTargeted = false
        }
    }
    
    private func addFilesForArchive() {
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("select_files", comment: "")
        openPanel.prompt = NSLocalizedString("add", comment: "")
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        
        openPanel.begin { response in
            guard response == .OK else { return }
            for url in openPanel.urls {
                appState.filesForArchiving.append(SecureFile(url: url))
            }
        }
    }
    
    private func addFolderForArchive() {
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("select_folder", comment: "")
        openPanel.prompt = NSLocalizedString("add", comment: "")
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        
        openPanel.begin { response in
            guard response == .OK else { return }
            for url in openPanel.urls {
                appState.filesForArchiving.append(SecureFile(url: url))
            }
        }
    }
    
    private func fileIcon(for url: URL) -> String {
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
