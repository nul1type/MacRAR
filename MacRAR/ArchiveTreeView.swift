import SwiftUI

struct ArchiveTreeView: View {
    @Binding var selectedFiles: Set<String>
    @Binding var hoveredFile: String?
    let items: [ArchiveItem]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    ArchiveItemView(
                        item: item,
                        selectedFiles: $selectedFiles,
                        hoveredFile: $hoveredFile
                    )
                }
            }
            .padding(4)
        }
    }
}

struct ArchiveItemView: View {
    @ObservedObject var item: ArchiveItem
    @Binding var selectedFiles: Set<String>
    @Binding var hoveredFile: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // Индикатор папки/файла
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundColor(item.isDirectory ? .yellow : .blue)
                
                // Название элемента
                Text(item.name)
                    .lineLimit(1)
                
                Spacer()
                
                // Кнопка раскрытия для папок
                if item.isDirectory && item.children != nil {
                    Button(action: {
                        withAnimation {
                            item.isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                selectedFiles.contains(item.fullPath) ? Color.blue.opacity(0.3) : 
                (hoveredFile == item.fullPath ? Color.gray.opacity(0.2) : Color.clear)
            )
            .cornerRadius(6)
            .onTapGesture(count: 2) {
                if item.isDirectory {
                    withAnimation {
                        item.isExpanded.toggle()
                    }
                }
            }
            .onTapGesture(count: 1) {
                toggleFileSelection(item.fullPath)
            }
            .onHover { hovering in
                hoveredFile = hovering ? item.fullPath : nil
            }
            
            // Вложенные элементы
            if item.isExpanded, let children = item.children {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(children) { child in
                        ArchiveItemView(
                            item: child,
                            selectedFiles: $selectedFiles,
                            hoveredFile: $hoveredFile
                        )
                        .padding(.leading, 16)
                    }
                }
            }
        }
    }
    
    private func toggleFileSelection(_ path: String) {
        if selectedFiles.contains(path) {
            selectedFiles.remove(path)
        } else {
            selectedFiles.insert(path)
        }
    }
}