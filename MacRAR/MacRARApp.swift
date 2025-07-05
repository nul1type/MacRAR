import SwiftUI
import Cocoa

//@main
//struct MacRARApp: App {
//    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
//    @StateObject var appState = AppState()
//    
//    var body: some Scene {
//        WindowGroup {
//            ContentView()
//                .environmentObject(appState)
//                .onOpenURL { url in
//                    appDelegate.handleRarFile(url: url, appState: appState)
//                }
//                .onAppear {
//                    if let initialFile = appDelegate.initialRarFile {
//                        appState.loadArchive(path: initialFile.path)
//                    }
//                }
//        }
//    }
//}

@main
struct MacRARApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
    @StateObject var appState = AppState()
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
            .environmentObject(appState)
               .onOpenURL { url in
                   appDelegate.handleRarFile(url: url, appState: appState)
               }
            .onAppear {
                appState.loadBookmarks()
                
                if let initialFile = appDelegate.initialRarFile {
                    // Автоматический запрос доступа для начального файла
                    if appState.autoRequestAccess(for: initialFile) {
                        appState.loadArchive(path: initialFile.path)
                    }
                }
            }
               .onChange(of: scenePhase) { newPhase in
                   switch newPhase {
                   case .active:
                       appState.loadBookmarks()
                   case .background:
                       appState.stopAccessingResources()
                   default: break
                   }
               }
        }
        .commands {
            // Дополнительные команды меню (если нужны)
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var initialRarFile: URL?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.argc > 1 {
            let filePath = CommandLine.arguments[1]
            let url = URL(fileURLWithPath: filePath)
            
            if url.pathExtension.lowercased() == "rar" {
                initialRarFile = url
            }
        }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "rar" {
                handleRarFile(url: url)
            }
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        if url.pathExtension.lowercased() == "rar" {
            handleRarFile(url: url)
        }
    }
    
    func handleRarFile(url: URL) {
        removeQuarantineAttribute(from: url)
        NotificationCenter.default.post(
            name: .loadRarFileNotification,
            object: nil,
            userInfo: ["filePath": url.path]
        )
    }
    
    
    
    func handleRarFile(url: URL, appState: AppState) {
        appState.requestAccessConfirmation(for: url) { granted in
            if granted {
                DispatchQueue.main.async {
                    appState.loadArchive(path: url.path)
                }
            }
        }
    }

    private func removeQuarantineAttribute(from url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        
        do {
            var resourceValues = URLResourceValues()
            resourceValues.quarantineProperties = nil
            var writableURL = url
            try writableURL.setResourceValues(resourceValues)
        } catch {
            let process = Process()
            process.launchPath = "/usr/bin/xattr"
            process.arguments = ["-d", "com.apple.quarantine", url.path]
            process.launch()
            process.waitUntilExit()
        }
    }
}

extension Notification.Name {
    static let loadRarFileNotification = Notification.Name("LoadRarFileNotification")
}
