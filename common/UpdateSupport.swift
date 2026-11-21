import AppKit
import Sparkle

/// Erzeugt pro App-Prozess genau einen langlebigen Sparkle-Controller.
/// Die aufrufenden Controller halten ihn als Feld über die gesamte Laufzeit.
func makeUpdaterController() -> SPUStandardUpdaterController {
    #if FAVENIO_SELFTEST
    let startingUpdater = false
    #else
    let startingUpdater = true
    #endif
    return SPUStandardUpdaterController(
        startingUpdater: startingUpdater,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Verdrahtet „Nach Updates suchen …" direkt auf Sparkle. Dadurch validiert
/// Sparkle den Eintrag auch während einer laufenden Suche oder Installation.
func installUpdateMenuItem(
    updaterController: SPUStandardUpdaterController
) {
    guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
    let identifier = NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")

    if let existing = appMenu.items.first(where: {
        $0.identifier == identifier
    }) {
        existing.action =
            #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        existing.target = updaterController
        return
    }

    let item = NSMenuItem(
        title: "Nach Updates suchen …",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    item.identifier = identifier
    item.target = updaterController

    let quitIndex = appMenu.items.firstIndex(where: {
        $0.action == #selector(NSApplication.terminate(_:))
    }) ?? appMenu.items.count
    appMenu.insertItem(item, at: quitIndex)
    appMenu.insertItem(.separator(), at: quitIndex + 1)
}

#if !FAVENIO_SELFTEST
func checkProductBundle(identifier: String, appName: String, helpers: [String]) -> Int32 {
    if let error = productBundleIssue(identifier: identifier, appName: appName, helpers: helpers) {
        fputs("BUNDLE FEHLER: \(error)\n", stderr)
        return 1
    }
    print("BUNDLE OK — \(identifier)")
    return 0
}

private func productBundleIssue(identifier: String, appName: String, helpers: [String]) -> String? {
    let info = Bundle.main.infoDictionary ?? [:]
    guard Bundle.main.bundleIdentifier == identifier,
          info["CFBundleShortVersionString"] as? String == favenioVersion else {
        return "unerwartete Bundle-ID oder Produktversion"
    }
    let files = FileManager.default
    guard let core = Bundle.main.path(forResource: "favenio", ofType: "py"),
          files.isReadableFile(atPath: core),
          let icon = info["CFBundleIconFile"] as? String,
          Bundle.main.url(forResource: icon, withExtension: "icns") != nil else {
        return "Suchkern oder App-Icon fehlt im App-Bundle"
    }
    let helperDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    for helper in helpers {
        guard files.isExecutableFile(atPath: helperDirectory.appendingPathComponent(helper).path) else {
            return "Helfer fehlt oder ist nicht ausführbar: " + helper
        }
    }
    guard let feed = info["SUFeedURL"] as? String,
          let feedURL = URL(string: feed),
          let scheme = feedURL.scheme, ["https", "http"].contains(scheme),
          feedURL.host != nil else {
        return "Sparkle-Feed ist keine gültige HTTP(S)-URL"
    }
    if let expectedFeed = ProcessInfo.processInfo.environment["FAVENIO_EXPECTED_UPDATE_FEED"],
       feed != expectedFeed {
        return "Sparkle-Feed im Bundle weicht vom gewählten Update-Feed ab"
    }
    guard info["SUPublicEDKey"] as? String == favenioSparklePublicKey,
          info["SUEnableAutomaticChecks"] as? Bool == true,
          info["SUAutomaticallyUpdate"] as? Bool == false,
          info["SUAllowsAutomaticUpdates"] as? Bool == false,
          info["SUEnableSystemProfiling"] as? Bool == false,
          info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
          info["SURequireSignedFeed"] as? Bool == true else {
        return "Sparkle-Signatur-, Update- oder Datenschutzwerte fehlen"
    }
    guard let frameworks = Bundle.main.privateFrameworksURL,
          FileManager.default.fileExists(
              atPath: frameworks.appendingPathComponent(
                  "Sparkle.framework"
              ).path
          ) else {
        return "Sparkle.framework fehlt im App-Bundle"
    }

    _ = NSApplication.shared
    // Der Controller bleibt inaktiv, damit die Bundle-Prüfung keinen Feed abruft.
    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    installMainMenu(appName: appName)
    installUpdateMenuItem(updaterController: controller)
    guard let item = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first(
        where: {
            $0.identifier
                == NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")
        }
    ),
    item.action == #selector(
        SPUStandardUpdaterController.checkForUpdates(_:)
    ),
    item.target === controller else {
        return "Update-Menüpunkt zielt nicht direkt auf Sparkle"
    }
    return nil
}
#endif
