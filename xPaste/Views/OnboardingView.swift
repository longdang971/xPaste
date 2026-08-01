import SwiftUI
import AppKit
import ServiceManagement

/// First-launch setup sheet: the four settings a new user has to get right before xPaste is
/// useful, in one screen, all writing straight to the same defaults the Settings window uses.
struct OnboardingView: View {
    /// Called when the user is done. The window is closed by the delegate, which then picks
    /// the first-launch flow back up (Accessibility permission).
    var onContinue: () -> Void

    @State private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("keepHistoryIndex") private var keepHistoryIndex: Int = HistoryRetention.defaultIndex

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)

            Text("Quick Start")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 18)

            Text("Set up and start using xPaste.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            card
                .padding(.top, 28)
                .padding(.horizontal, 26)

            Spacer(minLength: 20)

            Button(action: onContinue) {
                Text("Continue")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 150, height: 38)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 30)
        }
        .frame(width: OnboardingView.windowSize.width, height: OnboardingView.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    static let windowSize = CGSize(width: 540, height: 660)

    private var card: some View {
        VStack(spacing: 0) {
            OnboardingRow(title: "Run in background",
                          subtitle: "Open at login and always keep running") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            print("Launch at login error: \(error)")
                            // Registration failed — resync the toggle to the real state instead
                            // of leaving it stuck on the value the user just picked.
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
            }

            OnboardingDivider()

            OnboardingRow(title: "Show menu bar icon",
                          subtitle: "Keep xPaste one click away in the menu bar") {
                Toggle("", isOn: $showMenuBarIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: showMenuBarIcon) { _ in
                        NotificationCenter.default.post(name: .menuBarIconChanged, object: nil)
                    }
            }

            OnboardingDivider()

            OnboardingRow(title: "Activation shortcut",
                          subtitle: "Instantly access xPaste in any app") {
                HotkeyRecorderButton(style: .onboarding)
            }

            OnboardingDivider()

            OnboardingRow(title: "Clipboard history",
                          subtitle: "How long to retain copied content") {
                retentionSlider
            }
        }
        // A tint of the foreground rather than `controlBackgroundColor`: in light mode that
        // colour is the same white as the window behind it, and the card vanished.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var retentionSlider: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(keepHistoryIndex) },
                    set: { keepHistoryIndex = Int($0.rounded()) }
                ),
                in: 0...Double(HistoryRetention.lastIndex), step: 1
            )
            // Track the knob rather than centring the caption, so the value reads as belonging
            // to the position the user just dragged to.
            GeometryReader { geo in
                Text(HistoryRetention.summary(for: keepHistoryIndex))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: captionX(in: geo.size.width), y: 7)
            }
            .frame(height: 14)
        }
        .frame(width: 175)
    }

    /// Horizontal centre for the value caption: follows the knob, but stays inside the track
    /// so the longest label ("Forever") is never clipped at either end.
    private func captionX(in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let knob: CGFloat = 20
        let fraction = CGFloat(keepHistoryIndex) / CGFloat(HistoryRetention.lastIndex)
        let x = knob / 2 + (width - knob) * fraction
        let margin: CGFloat = 26
        return min(max(x, margin), max(margin, width - margin))
    }
}

private struct OnboardingRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct OnboardingDivider: View {
    var body: some View { Divider().padding(.horizontal, 16) }
}
