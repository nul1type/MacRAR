import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Darwin // Для доступа к errno

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
    
    @Published var quarantinedRARPath: String? = nil
    @Published var showGatekeeperWarning: Bool = false
    
    @Published var archiveCreationSuccess: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadSavedRARBinary()
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
    
   
    func retryRARBinaryCheck() {
        guard let path = quarantinedRARPath else {
            showGatekeeperWarning = false
            return
        }
        
        let url = URL(fileURLWithPath: path)
        statusMessage = NSLocalizedString("checking_rar_again", comment: "")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = url
            process.arguments = ["v", "-?"]
            
            do {
                try process.run()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.canCreateArchives = true
                        self.statusMessage = NSLocalizedString("rar_ready_message", comment: "")
                        self.showGatekeeperWarning = false
                    } else {
                        self.statusMessage = NSLocalizedString("gatekeeper_still_blocked", comment: "")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let nsError = error as NSError
                    if nsError.domain == NSPOSIXErrorDomain && (nsError.code == 13 || nsError.code == 1) {
                        self.statusMessage = NSLocalizedString("gatekeeper_still_blocked", comment: "")
                    } else {
                        self.statusMessage = NSLocalizedString("rar_activation_failed", comment: "") + ": " + error.localizedDescription
                    }
                }
            }
        }
    }
    
    
    func triggerGatekeeperDialog(for url: URL) {
        statusMessage = NSLocalizedString("triggering_gatekeeper", comment: "")
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Попытка 1: Прямой запуск через NSWorkspace
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.requiresUniversalLinks = false
                
                try NSWorkspace.shared.open(
                    url,
                    configuration: configuration
                )
                
                DispatchQueue.main.async {
                    self.statusMessage = NSLocalizedString("gatekeeper_triggered", comment: "")
                    
                    // Отложенная проверка через 3 секунды
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.retryRARBinaryCheck()
                    }
                }
                return
            } catch {
                print("Прямой запуск не удался: \(error)")
            }
            
            // Попытка 2: Через AppleScript и Finder
            DispatchQueue.main.async {
                self.statusMessage = NSLocalizedString("trying_alternative_method", comment: "")
            }
            
            let script = """
            tell application "Finder"
                activate
                open POSIX file "\(url.path)"
            end tell
            """
            
            let process = Process()
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", script]
            
            do {
                try process.run()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.statusMessage = NSLocalizedString("gatekeeper_triggered", comment: "")
                        
                        // Отложенная проверка через 3 секунды
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self.retryRARBinaryCheck()
                        }
                    } else {
                        self.statusMessage = NSLocalizedString("trigger_failed", comment: "") + " (код: \(process.terminationStatus))"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = NSLocalizedString("trigger_failed", comment: "") + ": " + error.localizedDescription
                }
            }
        }
    }
    
    func checkGatekeeperStatus(for url: URL) -> Bool {
        // 1. Проверка через безопасный запуск
        let canExecute = canExecuteBinary(at: url)
        
        // 2. Проверка через системные настройки (более надежный способ)
        if canExecute {
            return false // Не заблокирован
        }
        
        // 3. Проверка карантина как резервный вариант
        return isFileQuarantined(at: url)
    }

    private func canExecuteBinary(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["v", "-?"]
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            let nsError = error as NSError
            return !(nsError.domain == NSPOSIXErrorDomain && (nsError.code == 13 || nsError.code == 1))
        }
    }
    
    func handleRARSelection(url: URL) {
        resetRARState()
        
        // Проверка реального статуса Gatekeeper
        if checkGatekeeperStatus(for: url) {
            showGatekeeperWarning(path: url.path)
            return
        }
        
        requestRARAccess(url: url) { [weak self] granted in
            guard let self = self else { return }
            
            if granted {
                let secureFile = SecureFile(url: url)
                self.rarBinary = secureFile
                UserDefaults.standard.set(secureFile.bookmarkData, forKey: "rarBinaryBookmark")
                
                // Финализация установки
                self.finalizeRARSetup(url: url)
            } else {
                self.statusMessage = NSLocalizedString("rar_access_denied", comment: "")
            }
        }
    }

    private func finalizeRARSetup(url: URL) {
        // Проверка реальной работоспособности
        if canExecuteBinary(at: url) {
            canCreateArchives = true
            statusMessage = NSLocalizedString("rar_ready_message", comment: "")
        } else {
            // Даже если проверки не показали блокировку, но запуск не работает
            showGatekeeperWarning(path: url.path)
        }
    }

    func checkRARBinary() {
        guard let rarURL = rarBinary?.url else {
            canCreateArchives = false
            statusMessage = NSLocalizedString("rar_not_found", comment: "")
            return
        }
        
        // Проверка реального статуса
        if checkGatekeeperStatus(for: rarURL) {
            showGatekeeperWarning(path: rarURL.path)
            return
        }
        
        // Проверка работоспособности
        if canExecuteBinary(at: rarURL) {
            canCreateArchives = true
            statusMessage = NSLocalizedString("rar_ready_message", comment: "")
        } else {
            statusMessage = NSLocalizedString("rar_activation_failed", comment: "")
        }
    }

    public func isFileQuarantined(at url: URL) -> Bool {
        // 1. Проверка через FileManager (основной способ)
        if let resourceValues = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]) {
            if resourceValues.quarantineProperties != nil {
                return true
            }
        }
        
        // 2. Альтернативный способ через POSIX
        let path = url.path
        let attrName = "com.apple.quarantine"
        
        // Сначала получаем размер атрибута
        let bufferSize = getxattr(path, attrName, nil, 0, 0, 0)
        
        // Если размер > 0 - атрибут существует
        if bufferSize > 0 {
            return true
        }
        
        // Обработка ошибок (ENOATTR = атрибут отсутствует)
        return errno != ENOATTR
    }
    
    private func loadSavedRARBinary() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "rarBinaryBookmark") else { return }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                // Обновляем закладку если устарела
                let newBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(newBookmark, forKey: "rarBinaryBookmark")
            }
            
            let secureFile = SecureFile(url: url)
            rarBinary = secureFile
            
            // Проверяем доступность
            verifyRARBinary(url: url)
        } catch {
            statusMessage = NSLocalizedString("rar_restore_error", comment: "") + ": " + error.localizedDescription
        }
    }
    
    private var rarActivationAttempted: Bool = false
    

    private func verifyRARBinary(url: URL) {
        let process = Process()
        process.executableURL = url
        process.arguments = ["v", "-?"] // Безопасная команда
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(process.terminationStatus))
            }
            
            // Успешное выполнение
            canCreateArchives = true
            statusMessage = NSLocalizedString("rar_ready_message", comment: "")
        } catch {
            let nsError = error as NSError
            
            // Обработка ошибок Gatekeeper
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == 13 || nsError.code == 1) {
                showGatekeeperWarning(path: url.path)
            } else {
                statusMessage = NSLocalizedString("rar_activation_failed", comment: "") + ": " + error.localizedDescription
            }
        }
    }

    private func showGatekeeperWarning(path: String) {
        quarantinedRARPath = path
        showGatekeeperWarning = true
        canCreateArchives = false
        statusMessage = NSLocalizedString("gatekeeper_blocked", comment: "")
    }

    
        
    private func requestRARAccess(url: URL, completion: @escaping (Bool) -> Void) {
            // Уже есть доступ?
            if hasPersistentAccess(to: url) {
                completion(true)
                return
            }
            
            // Получаем временный доступ для показа диалога
            guard url.startAccessingSecurityScopedResource() else {
                completion(false)
                return
            }
            
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("rar_access_title", comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("rar_access_message_format", comment: ""),
                    url.lastPathComponent
                )
                alert.addButton(withTitle: NSLocalizedString("access_request_button", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))
                
                let response = alert.runModal()
                url.stopAccessingSecurityScopedResource()
                
                if response == .alertFirstButtonReturn {
                    // Сохраняем закладку для постоянного доступа
                    self.saveBookmark(for: url)
                    
                    // Начинаем постоянный доступ
                    if url.startAccessingSecurityScopedResource() {
                        self.accessedURLs.append(url)
                        completion(true)
                    } else {
                        completion(false)
                    }
                } else {
                    completion(false)
                }
            }
        }
    
    
        
        private func activateGatekeeperPrompt(for url: URL) {
            statusMessage = NSLocalizedString("activating_rar", comment: "")
            
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = url
                process.arguments = [] // Пустые аргументы
                
                do {
                    // Настраиваем pipe для предотвращения блокировки
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    
                    try process.run()
                    process.waitUntilExit()
                    
                    DispatchQueue.main.async {
                        self.statusMessage = NSLocalizedString("gatekeeper_activated", comment: "")
                        self.showGatekeeperWarning = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        if (error as NSError).code == 13 {
                            self.statusMessage = NSLocalizedString("gatekeeper_activated", comment: "")
                            self.showGatekeeperWarning = true
                        } else {
                            self.statusMessage = NSLocalizedString("rar_launch_error", comment: "") + ": " + error.localizedDescription
                        }
                    }
                }
            }
        }
        
        private func activateGatekeeperPrompt() {
            guard let rarURL = rarBinary?.url else { return }
            
            statusMessage = NSLocalizedString("activating_rar", comment: "")
            
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = rarURL
                process.arguments = ["v", "-?"]
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    DispatchQueue.main.async {
                        // Если процесс завершился успешно
                        if process.terminationStatus == 0 {
                            self.canCreateArchives = true
                            self.statusMessage = NSLocalizedString("rar_ready_message", comment: "")
                        } else {
                            self.statusMessage = NSLocalizedString("rar_execution_failed", comment: "")
                            self.checkGatekeeperStatus()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        // Gatekeeper блокировка (EACCES = 13)
                        if (error as NSError).code == 13 {
                            self.statusMessage = NSLocalizedString("gatekeeper_activated", comment: "")
                            self.showGatekeeperWarning = true
                        } else {
                            self.statusMessage = NSLocalizedString("rar_launch_error", comment: "") + ": " + error.localizedDescription
                        }
                    }
                }
                
                self.rarActivationAttempted = true
            }
        }
        
        private func checkGatekeeperStatus() {
            guard let rarURL = rarBinary?.url else { return }
            
            // Проверяем, появилась ли опция в настройках
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let process = Process()
                process.executableURL = rarURL
                process.arguments = ["v", "-?"]
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        self.canCreateArchives = true
                        self.statusMessage = NSLocalizedString("rar_ready_message", comment: "")
                        self.showGatekeeperWarning = false
                    }
                } catch {
                    // Оставляем предупреждение включенным
                }
            }
        }
        
        func fixGatekeeperIssue() {
            guard let rarURL = rarBinary?.url else { return }
            
            // Просто повторяем активацию
            activateGatekeeperPrompt()
        }
    
    private let bookmarksKey = "savedBookmarks"
    private var accessedURLs: [URL] = []
    
        
        private func requestPersistentAccessForRAR(url: URL, completion: @escaping (Bool) -> Void) {
            // Уже есть доступ?
            if hasPersistentAccess(to: url) {
                completion(true)
                return
            }
            
            // Показываем системный запрос
            DispatchQueue.main.async {
                let openPanel = NSOpenPanel()
                openPanel.title = NSLocalizedString("rar_access_title", comment: "")
                openPanel.message = NSLocalizedString("rar_access_message", comment: "")
                openPanel.prompt = NSLocalizedString("grant_access", comment: "")
                openPanel.canChooseFiles = true
                openPanel.allowsMultipleSelection = false
                openPanel.directoryURL = url.deletingLastPathComponent()
                openPanel.nameFieldStringValue = url.lastPathComponent
                
                openPanel.begin { response in
                    if response == .OK, let selectedURL = openPanel.urls.first {
                        self.saveBookmark(for: selectedURL)
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            }
        }
        
        
        private func activateGatekeeper(for url: URL) {
            guard let secureFile = rarBinary else { return }
            
            // Пробный запуск для активации Gatekeeper
            let process = Process()
            process.executableURL = url
            process.arguments = ["v", "-?"]
            
            do {
                try secureFile.accessSecurityScopedResource {
                    try process.run()
                    process.waitUntilExit()
                }
                
                // Даем системе время на обработку
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.checkRARBinaryValidity()
                }
            } catch {
                // Ожидаемая ошибка - Gatekeeper блокировка
                if (error as NSError).code == 13 || process.terminationStatus == 153 {
                    self.showGatekeeperWarning(path: url.path)
                } else {
                    self.statusMessage = NSLocalizedString("rar_activation_failed", comment: "") + ": " + error.localizedDescription
                }
            }
        }
    
    private func performRARValidation(for url: URL) {
            // Проверка 1: Существует ли файл
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async {
                    self.statusMessage = NSLocalizedString("rar_not_found", comment: "")
                    self.canCreateArchives = false
                }
                return
            }
            
            // Проверка 2: Является ли исполняемым
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                DispatchQueue.main.async {
                    self.statusMessage = NSLocalizedString("rar_not_executable", comment: "")
                    self.canCreateArchives = false
                }
                return
            }
            
            // Проверка прав доступа
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                // Попробуем исправить права
                do {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: url.path
                    )
                } catch {
                    DispatchQueue.main.async {
                        self.statusMessage = NSLocalizedString("rar_permission_error", comment: "")
                        self.canCreateArchives = false
                    }
                    return
                }
                
                // Повторная проверка прав
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    DispatchQueue.main.async {
                        self.statusMessage = NSLocalizedString("rar_permission_fix_failed", comment: "")
                        self.canCreateArchives = false
                    }
                    return
                }
                
                // Продолжаем проверку, если права исправлены
                self.performRARExecutionTest(for: url)
                return
            }
            
            // Если права в порядке, выполняем тест
            self.performRARExecutionTest(for: url)
        }
        
        private func performRARExecutionTest(for url: URL) {
            let testProcess = Process()
            testProcess.executableURL = url
            testProcess.arguments = ["v", "-?"]
            
            // Используем выходные данные для диагностики
            let outputPipe = Pipe()
            testProcess.standardOutput = outputPipe
            testProcess.standardError = outputPipe
            
            do {
                try testProcess.run()
                testProcess.waitUntilExit()
                
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                print("RAR output: \(output)")
                
                DispatchQueue.main.async {
                    // Успешное выполнение
                    if testProcess.terminationStatus == 0 {
                        self.canCreateArchives = true
                        self.statusMessage = NSLocalizedString("rar_ready_message", comment: "")
                        return
                    }
                    
                    // Специфическая ошибка Gatekeeper
                    if testProcess.terminationStatus == 153 {
                        self.showGatekeeperWarning(path: url.path)
                        return
                    }
                    
                    // Проверяем вывод на наличие информации о версии
                    if output.lowercased().contains("rar") || output.lowercased().contains("version") {
                        self.canCreateArchives = true
                        self.statusMessage = NSLocalizedString("rar_ready_message", comment: "")
                        return
                    }
                    
                    // Другие ошибки
                    self.statusMessage = String(
                        format: NSLocalizedString("rar_execution_failed", comment: ""),
                        testProcess.terminationStatus
                    )
                    self.canCreateArchives = false
                }
            } catch {
                DispatchQueue.main.async {
                    // Ошибка запуска (EACCES = 13)
                    if (error as NSError).code == 13 {
                        self.showGatekeeperWarning(path: url.path)
                    } else {
                        self.statusMessage = String(
                            format: NSLocalizedString("rar_launch_error", comment: ""),
                            error.localizedDescription
                        )
                        self.canCreateArchives = false
                    }
                }
            }
        }
    
        
        func checkRARBinaryValidity() {
            guard let rarURL = rarBinary?.url else {
                DispatchQueue.main.async {
                    self.canCreateArchives = false
                }
                return
            }
            
            // Активируем Gatekeeper prompt
            triggerGatekeeperPrompt(for: rarURL)
            
            // Даем системе время обработать запрос
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.performRARValidation(for: rarURL)
            }
        }
        
        private func triggerGatekeeperPrompt(for url: URL) {
            // Создаем временный процесс для активации Gatekeeper
            let process = Process()
            process.executableURL = url
            process.arguments = ["v", "-?"]
            
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Игнорируем ошибку - это ожидаемо
            }
        }
        
    func resetRARState() {
        quarantinedRARPath = nil
        showGatekeeperWarning = false
        canCreateArchives = false
        statusMessage = NSLocalizedString("checking_rar", comment: "")
    }
        

    
    
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
    
    
    // Create a new archive
//    func createArchive() {
//        guard let rarFile = rarBinary else {
//            statusMessage = NSLocalizedString("no_rar_binary", comment: "")
//            return
//        }
//        
//        let savePanel = NSSavePanel()
//        savePanel.title = NSLocalizedString("save_archive", comment: "")
//        savePanel.nameFieldStringValue = archiveName.isEmpty ?
//            NSLocalizedString("new_archive", comment: "") : archiveName
//        savePanel.allowedContentTypes = [UTType(filenameExtension: "rar") ?? .archive]
//        
//        savePanel.begin { response in
//            guard response == .OK, let archiveURL = savePanel.url else {
//                self.statusMessage = NSLocalizedString("archive_creation_canceled", comment: "")
//                return
//            }
//            
//            self.isCreatingArchive = true
//            self.statusMessage = NSLocalizedString("creating_archive", comment: "")
//            
//            DispatchQueue.global(qos: .userInitiated).async {
//                do {
//                    let tempDir = FileManager.default.temporaryDirectory
//                        .appendingPathComponent("rar_\(UUID().uuidString)", isDirectory: true)
//                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//                    
//                    for (index, secureFile) in self.filesForArchiving.enumerated() {
//                        try secureFile.accessSecurityScopedResource {
//                            let destination = tempDir.appendingPathComponent(secureFile.url.lastPathComponent)
//                            
//                            if FileManager.default.fileExists(atPath: destination.path) {
//                                try FileManager.default.removeItem(at: destination)
//                            }
//                            
//                            try FileManager.default.copyItem(at: secureFile.url, to: destination)
//                        }
//                    }
//                    
//                    let fileNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
//                    var arguments = ["a", archiveURL.path]
//                    arguments.append(contentsOf: fileNames)
//                    
//                    var processOutput = ""
//                    
//                    try rarFile.accessSecurityScopedResource {
//                        let process = Process()
//                        process.executableURL = rarFile.url
//                        process.arguments = arguments
//                        process.currentDirectoryURL = tempDir
//                        
//                        let outputPipe = Pipe()
//                        process.standardOutput = outputPipe
//                        process.standardError = outputPipe
//                        
//                        try process.run()
//                        process.waitUntilExit()
//                        
//                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
//                        processOutput = String(data: outputData, encoding: .utf8) ?? ""
//                    }
//                    
//                    try FileManager.default.removeItem(at: tempDir)
//                    
//                    DispatchQueue.main.async {
//                        self.isCreatingArchive = false
//                        self.statusMessage = processOutput
//                    }
//                } catch {
//                    DispatchQueue.main.async {
//                        self.isCreatingArchive = false
//                        self.statusMessage = String(
//                            format: NSLocalizedString("error_general", comment: ""),
//                            error.localizedDescription
//                        )
//                    }
//                }
//            }
//        }
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
        
        savePanel.begin { [weak self] response in
            guard let self = self else { return }
            
            guard response == .OK, let archiveURL = savePanel.url else {
                self.statusMessage = NSLocalizedString("archive_creation_canceled", comment: "")
                return
            }
            
            self.isCreatingArchive = true
            self.statusMessage = NSLocalizedString("creating_archive", comment: "")
            self.archiveCreationSuccess = false
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("rar_\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    for secureFile in self.filesForArchiving {
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
                        self.statusMessage = processOutput.isEmpty ?
                            NSLocalizedString("archive_created_success", comment: "") :
                            processOutput
                        
                        // Устанавливаем флаг успеха
                        self.archiveCreationSuccess = true
                        
                        // Сбрасываем состояние через 1 секунду
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.showArchiveCreation = false
                            self.archiveCreationSuccess = false
                            self.filesForArchiving.removeAll()
                            self.archiveName = ""
                        }
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
    
//    // Check for existing RAR binary
//    func checkRARBinary() {
//        if let bookmarkData = UserDefaults.standard.data(forKey: "rarBinaryBookmark") {
//            do {
//                var isStale = false
//                let url = try URL(
//                    resolvingBookmarkData: bookmarkData,
//                    options: .withSecurityScope,
//                    relativeTo: nil,
//                    bookmarkDataIsStale: &isStale
//                )
//                
//                if isStale {
//                    let secureFile = SecureFile(url: url)
//                    UserDefaults.standard.set(secureFile.bookmarkData, forKey: "rarBinaryBookmark")
//                    self.rarBinary = secureFile
//                } else {
//                    self.rarBinary = SecureFile(url: url)
//                }
//                
//                canCreateArchives = true
//            } catch {
//                statusMessage = String(
//                    format: NSLocalizedString("rar_restore_error", comment: ""),
//                    error.localizedDescription
//                )
//            }
//        }
//    }

}

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
