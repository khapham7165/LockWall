import SwiftUI

/// One-screen first-run welcome: what LockWall does, where it lives, open at login.
struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Keys.hasOnboarded) private var hasOnboarded = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Welcome to LockWall")
                    .font(.system(size: 26, weight: .bold))
                Text("Give your lock screen its own wallpaper, and switch your desktop and screen saver from the menu bar.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "lock.display", title: "A lock screen of its own",
                        text: "Black, a color or any image while your Mac is locked. Your desktop returns when you unlock.")
                Feature(symbol: "photo.on.rectangle.angled", title: "Wallpapers in one click",
                        text: "Save Apple wallpapers — even dynamic and Aerial ones — and switch between them anytime.")
                Feature(symbol: "sparkles.tv", title: "Screen saver and hot corners",
                        text: "Change them without digging through System Settings.")
            }
            .padding(.horizontal, 8)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("LockWall lives in the menu bar:")
                        Image(systemName: "lock.display")
                    }
                    .foregroundStyle(.secondary)
                    LaunchAtLoginToggle()
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Button {
                hasOnboarded = true
                dismissWindow(id: "welcome")
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(width: 460)
        .onAppear { NSApp.activate() }
        .onDisappear { hasOnboarded = true }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
