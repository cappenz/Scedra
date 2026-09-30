//
//  ScedraApp.swift
//  Scedra
//

import SwiftUI
import UserNotifications

@main
struct ScedraApp: App {
    @UIApplicationDelegateAdaptor(ScedraAppDelegate.self) private var appDelegate

    init() {
        ScedraLocale.followPhoneLanguage()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class ScedraAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScedraLocale.followPhoneLanguage()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        LeaveToNavigateNotifier.registerCategory()
        return true
    }
}
