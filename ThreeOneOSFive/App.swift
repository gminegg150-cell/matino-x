import SwiftUI
import UIKit
import AVKit
import AVFoundation

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var showSplash = true
    @State private var showBanner = true
    @State private var updateOffer: AppUpdateChecker.Offer?
    @StateObject private var license = BaypassLicense.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        setupLogCapture()
        log("app: MATINO X launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(patchStore)
                    .environmentObject(repositoryStore)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(showOnboarding || !license.isActivated ? 0 : 1)
                    .allowsHitTesting(!showOnboarding && license.isActivated)

                if showOnboarding && license.isActivated {
                    OnboardingView {
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }

                if !license.isActivated {
                    BaypassActivationView()
                        .zIndex(2)
                }

                if showSplash {
                    SplashView()
                        .zIndex(3)
                        .allowsHitTesting(false)
                }

                if showBanner {
                    BannerAnimView()
                        .zIndex(4)
                        .allowsHitTesting(false)
                }



            }
            .preferredColorScheme(.dark)
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding && license.isActivated)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .onAppear {
                license.revalidateStoredKey()
                if !showOnboarding && license.isActivated {
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding, license.isActivated else { return }
                appState.detectSupport()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}

/// MATINO X: launch splash - video at native size (no stretch/crop), screen blend.
struct SplashView: View {
    @State private var player: AVPlayer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .blendMode(.screen)
                    .opacity(0.6)
                    .onAppear {
                        player.play()
                    }
            }
        }
        .onAppear {
            if player == nil,
               let url = Bundle.main.url(forResource: "snow_overlay", withExtension: "mp4") {
                let p = AVPlayer(url: url)
                p.isMuted = true
                p.actionAtItemEnd = .none
                self.player = p
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: p.currentItem,
                    queue: .main
                ) { _ in
                    p.seek(to: .zero)
                    p.play()
                }
                p.play()
            }
        }
        // Resume when returning from background - video must keep playing.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                player?.play()
            }
        }
    }
}

// MATINO X: animated strip shown across all tabs (AIM/HOLOGRAM/SKIN/Settings).
// MATINO X: self-made animated neon strip (pure SwiftUI, no video).
// Shown across AIM / HOLOGRAM / SKIN / Settings.
struct BannerAnimView: View {
    @State private var phase: CGFloat = 0
    @State private var shimmer: CGFloat = -260
    private let tick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private let words = ["MATINO X", "ONLINE PATCHES", "FREE FIRE", "AIM • HOLOGRAM • SKIN"]

    var body: some View {
        ZStack(alignment: .leading) {
            // Deep bar background
            LinearGradient(
                colors: [Color.black.opacity(0.95), Color(white: 0.07), Color.black.opacity(0.95)],
                startPoint: .leading, endPoint: .trailing
            )

            // Moving neon shimmer sweep
            LinearGradient(
                colors: [.clear, Color.green.opacity(0.35), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 220)
            .offset(x: shimmer)

            // Neon glowing text with pulse
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.green)
                    .shadow(color: .green, radius: 6)
                Text(words[Int(phase) % words.count])
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.green)
                    .shadow(color: .green.opacity(0.9), radius: 8)
                    .animation(.easeInOut(duration: 0.35), value: phase)
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green, radius: 6)
                    .opacity(0.5 + 0.5 * sin(Double(phase) * 2.0))
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 46)
        .clipped()
        .onReceive(tick) { _ in
            shimmer += 4
            if shimmer > 420 { shimmer = -260 }
            phase += 0.012
        }
    }
}
