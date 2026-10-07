//
//  main.swift
//  MacMonMenu
//
//  Created by Jose Goncalves on 29/03/2026.
//

import AppKit
import SwiftTerm
import UserNotifications

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    weak var termVC: TerminalViewController?
    private var didOfferMacmonUpdate = false
    private var macmonUpgradeInFlight = false

    override init() {
        super.init()
        print("🔧 AppDelegate init")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Launched")

        NSApp.setActivationPolicy(.accessory) // No Dock icon

        // --- Menu bar icon ---
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "macmon")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // --- Popover ---
        popover = NSPopover()
        popover.contentSize = NSSize(width: 820, height: 460)
        popover.behavior = .transient  // Click outside = dismiss
        popover.animates = true
        popover.delegate = self

        UNUserNotificationCenter.current().delegate = self
        offerMacmonUpdateIfNeeded()
    }

    /// Shows banners while this menu-bar app is the active process.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func offerMacmonUpdateIfNeeded() {
        Task.detached(priority: .utility) {
            guard let update = MacmonUpdater.checkForUpdate() else { return }
            await MainActor.run {
                delegate.promptToUpdateMacmon(update)
            }
        }
    }

    private func promptToUpdateMacmon(_ update: MacmonUpdate) {
        guard !didOfferMacmonUpdate, !macmonUpgradeInFlight else { return }
        didOfferMacmonUpdate = true

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "A new macmon is available"
        alert.informativeText = "macmon \(update.installed) is installed. Homebrew has \(update.latest). Update it in the background?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startMacmonUpgrade(to: update.latest)
    }

    private func startMacmonUpgrade(to version: String) {
        macmonUpgradeInFlight = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task.detached(priority: .utility) {
                let outcome = MacmonUpdater.upgrade()
                await MainActor.run {
                    delegate.finishMacmonUpgrade(outcome, version: version)
                }
            }
        }
    }

    private func finishMacmonUpgrade(_ outcome: MacmonUpgradeOutcome, version: String) {
        macmonUpgradeInFlight = false
        switch outcome {
        case .success:
            announce(
                title: "macmon updated",
                body: "macmon \(version) is installed. Open the menu to use the new version."
            )
        case .failure(let message):
            presentAlert(title: "Couldn't update macmon", message: message)
        }
    }

    private func announce(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                allowed = true
            default:
                allowed = false
            }
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request)
            } else {
                Task { @MainActor in
                    delegate.presentAlert(title: title, message: body)
                }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.runModal()
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Fresh terminal view controller every time
            let vc = TerminalViewController()
            termVC = vc
            popover.contentViewController = vc
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        termVC?.killProcess()
        popover.contentViewController = nil
        termVC = nil
    }
}

// MARK: - TerminalViewController

class TerminalViewController: NSViewController {

    private var terminalView: LocalProcessTerminalView!

    // macmon path — checks both Homebrew locations
    private let macmonPath: String = {
        let candidates = [
            "/opt/homebrew/bin/macmon",  // Apple Silicon
            "/usr/local/bin/macmon",     // Intel
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/opt/homebrew/bin/macmon"
    }()

    override func loadView() {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 460)
        terminalView = LocalProcessTerminalView(frame: frame)
        terminalView.configureNativeColors()
        terminalView.layer?.backgroundColor = NSColor.black.cgColor
        self.view = terminalView
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        terminalView.startProcess(
            executable: macmonPath,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" }
        )
    }

    func killProcess() {
        terminalView?.process?.terminate()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
