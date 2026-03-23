import SwiftUI
import AppKit

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window != nsView.window {
            Task { @MainActor in self.window = nsView.window }
        }
    }
}

// MARK: - OnboardingView

struct OnboardingView: View {
    @Binding var isSignedIn: Bool
    @State private var authViewModel = AuthViewModel()
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var hostWindow: NSWindow?

    // Animation states
    @State private var showCard = false
    @State private var showIcon = false
    @State private var iconDrop: CGFloat = -40
    @State private var iconRotation: Double = -12
    @State private var iconScale: CGFloat = 0.3
    @State private var showName = false
    @State private var showTagline = false
    @State private var showButton = false
    @State private var isButtonHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Ambient orbs
    @State private var orb1Offset: CGSize = CGSize(width: -140, height: -100)
    @State private var orb2Offset: CGSize = CGSize(width: 160, height: 80)
    @State private var orb3Offset: CGSize = CGSize(width: -60, height: 140)
    @State private var orbsVisible = false

    var body: some View {
        ZStack {
            // MARK: - Deep black background
            BrandColor.onboardingBackground
                .ignoresSafeArea()

            // Ambient lights — brand colors
            ambientLights

            // Content
            VStack(spacing: 0) {
                Spacer()

                glassContent

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor(window: $hostWindow))
        .clipped()
        .onAppear {
            runAnimationSequence()
            hideTrafficLights(true)
        }
        .onChange(of: hostWindow) { _, newWindow in
            if newWindow != nil {
                hideTrafficLights(true)
            }
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue {
                withAnimation(.easeOut(duration: 0.3)) {
                    orb1Offset = .zero
                    orb2Offset = .zero
                    orb3Offset = .zero
                }
            }
        }
        .onDisappear {
            withAnimation(VikAnimation.contentSwitch) { orbsVisible = false }
            hideTrafficLights(false)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Glass Content (macOS 26+)

    @available(macOS 26, *)
    private var glassContent: some View {
        GlassEffectContainer(spacing: 20) {
            VStack(spacing: 0) {
                // Viking helmet — hero icon (glass-specific styling)
                Image("VikLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.xxl))
                    .opacity(showIcon ? 1 : 0)
                    .scaleEffect(iconScale)
                    .rotationEffect(.degrees(iconRotation))
                    .offset(y: iconDrop)

                Spacer().frame(height: 20)

                onboardingInnerContent { glassSignInButton }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 48)
            .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.xl))
            .scaleEffect(showCard ? 1 : 0.8)
            .opacity(showCard ? 1 : 0)
        }
    }

    // MARK: - Shared Inner Content

    @ViewBuilder
    private func onboardingInnerContent<B: View>(@ViewBuilder signInButton: () -> B) -> some View {
        // App name
        Text("Vik")
            .font(Typography.displayHero)
            .tracking(-1)
            .foregroundStyle(.white)
            .opacity(showName ? 1 : 0)
            .offset(y: showName ? 0 : 12)

        Spacer().frame(height: 4)

        // Tagline
        Text("CONQUER YOUR INBOX")
            .font(Typography.onboardingSubtitle)
            .tracking(3)
            .foregroundStyle(.white.opacity(0.75))
            .opacity(showTagline ? 1 : 0)

        Spacer().frame(height: 36)

        // Google Sign-In button
        signInButton()
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton ? 0 : 24)

        errorLabel
    }

    // MARK: - Error Label

    @ViewBuilder
    private var errorLabel: some View {
        if let error = signInError {
            Text(error)
                .font(Typography.captionSmallRegular)
                .foregroundStyle(SemanticColor.error)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .opacity(showButton ? 1 : 0)
        }
    }

    // MARK: - Sign-In Buttons

    @available(macOS 26, *)
    private var glassSignInButton: some View {
        Button {
            Task { await handleSignIn() }
        } label: {
            signInLabel
        }
        .buttonStyle(.glass)
        .disabled(isSigningIn)
        .scaleEffect(isButtonHovered ? ScaleToken.emphasis : 1.0)
        .animation(VikAnimation.springSnappy, value: isButtonHovered)
        .onHover { isButtonHovered = $0 }
    }

    private var signInLabel: some View {
        HStack(spacing: 12) {
            Group {
                if isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    GoogleLogo()
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 20, height: 20)
            Text(isSigningIn ? "Signing in\u{2026}" : "Continue with Google")
                .font(Typography.onboardingSubtitle)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(minWidth: 260)
    }

    // MARK: - Ambient Lights

    private var ambientLights: some View {
        ZStack {
            // Brand blue orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [BrandColor.blue.opacity(0.35), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
                .frame(width: 500, height: 500)
                .offset(orb1Offset)
                .blur(radius: 90)

            // Violet bridge orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [BrandColor.violet.opacity(0.28), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 420, height: 420)
                .offset(orb2Offset)
                .blur(radius: 80)

            // Brand coral orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [BrandColor.coral.opacity(0.20), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 160
                    )
                )
                .frame(width: 340, height: 340)
                .offset(orb3Offset)
                .blur(radius: 70)
        }
        .opacity(orbsVisible ? 1 : 0)
    }

    // MARK: - Animation Sequence

    private func runAnimationSequence() {
        if reduceMotion {
            orbsVisible = true
            showCard = true
            showIcon = true
            iconDrop = 0
            iconRotation = 0
            iconScale = 1.0
            showName = true
            showTagline = true
            showButton = true
            return
        }

        // 1. Ambient orbs fade in
        withAnimation(VikAnimation.onboardingAmbient) {
            orbsVisible = true
        }
        startOrbAnimations()

        // 2. Glass card scales up
        withAnimation(VikAnimation.onboardingCardEntrance.delay(0.3)) {
            showCard = true
        }

        // 3. Viking helmet drops in with rotation + bounce
        withAnimation(VikAnimation.onboardingIconBounce.delay(0.7)) {
            showIcon = true
            iconDrop = 0
            iconRotation = 0
            iconScale = 1.0
        }

        // 4. "Vik" text fades + slides up
        withAnimation(VikAnimation.onboardingReveal.delay(1.1)) {
            showName = true
        }

        // 5. Tagline fades in
        withAnimation(VikAnimation.onboardingRevealShort.delay(1.4)) {
            showTagline = true
        }

        // 6. Sign-in button
        withAnimation(VikAnimation.onboardingButtonEntrance.delay(1.8)) {
            showButton = true
        }
    }

    private func startOrbAnimations() {
        guard !reduceMotion else { return }
        withAnimation(VikAnimation.orbDrift(duration: 9)) {
            orb1Offset = CGSize(width: 120, height: 80)
        }
        withAnimation(VikAnimation.orbDrift(duration: 11, delay: 0.5)) {
            orb2Offset = CGSize(width: -140, height: -90)
        }
        withAnimation(VikAnimation.orbDrift(duration: 10, delay: 1.0)) {
            orb3Offset = CGSize(width: 90, height: -110)
        }
    }

    // MARK: - Sign In

    private func handleSignIn() async {
        isSigningIn = true
        signInError = nil
        await authViewModel.signIn()
        isSigningIn = false
        if authViewModel.hasAccounts {
            hideTrafficLights(false)
            withAnimation(reduceMotion ? nil : VikAnimation.onboardingTransition) {
                isSignedIn = true
            }
        } else {
            signInError = authViewModel.error ?? "Sign-in failed. Please try again."
        }
    }

    // MARK: - Window Chrome

    private func hideTrafficLights(_ hide: Bool) {
        guard let window = hostWindow else { return }
        if hide {
            window.toolbar = nil
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(BrandColor.onboardingBackground)
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.backgroundColor = .windowBackgroundColor
            window.appearance = nil
        }
    }
}
