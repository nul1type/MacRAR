import Foundation
import Combine

class AppState: ObservableObject {
    // Основные свойства
    @Published var selectedRARFilePath: String = ""
    @Published var statusMessage: String = "Выберите RAR архив"
    @Published var archiveItems: [ArchiveItem] = []
    @Published var archiveFiles: [String] = []
    @Published var selectedFiles: Set<String> = []
    
    // Состояния для создания архива
    @Published var showArchiveCreation = false
    @Published var filesForArchiving: [SecureFile] = []
    @Published var archiveName = ""
    @Published var isCreatingArchive = false
    
    // Бинарник rar
    @Published var rarBinary: SecureFile?
    @Published var canCreateArchives = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Подписка на уведомления о загрузке файлов
        NotificationCenter.default.publisher(for: .loadRarFileNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let filePath = notification.userInfo?["filePath"] as? String {
                    self?.loadArchive(path: filePath)
                }
            }
            .store(in: &cancellables)
        
        // Проверка rar при запуске
        checkRARBinary()
    }
    
    func loadArchive(path: String) {
        selectedRARFilePath = path
        statusMessage = "Загрузка архива: \(URL(fileURLWithPath: path).lastPathComponent)"
        
        // Здесь будет вызов вашей функции для загрузки содержимого архива
        // Временно используем заглушку
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.statusMessage = "Архив загружен: \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }
    
    // MARK: - Проверка rar при запуске
    private func checkRARBinary() {
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
                    // Обновляем закладку
                    let secureFile = SecureFile(url: url)
                    UserDefaults.standard.set(secureFile.bookmarkData, forKey: "rarBinaryBookmark")
                    self.rarBinary = secureFile
                } else {
                    self.rarBinary = SecureFile(url: url)
                }
                
                canCreateArchives = true
            } catch {
                print("⚠️ Ошибка восстановления RAR: \(error)")
            }
        }
    }
}