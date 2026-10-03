import SwiftUI

/// Navigation for the whole app: the thread list is home; threads push onto it.
@MainActor
@Observable
final class Router {
    var path: [ThreadRef] = []
    var showNewThread = false
    var showSettings = false
    var showPairing = false

    func open(_ ref: ThreadRef) {
        if path.last != ref { path = [ref] }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()

    var body: some View {
        Group {
            if model.hasEnvironments {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: ThreadRef.self) { ref in
                            ThreadScreen(ref: ref)
                        }
                }
                .sheet(isPresented: $router.showNewThread) {
                    NewThreadView()
                }
                .sheet(isPresented: $router.showSettings) {
                    SettingsView()
                }
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $router.showPairing) {
            NavigationStack { PairingView() }
        }
        .environment(router)
        .background(Palette.canvas)
    }
}

/// First launch: what Helm is and how to connect it.
struct WelcomeView: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HelmMark(size: 88)
            Text("Helm")
                .font(Typography.wordmark)
                .foregroundStyle(Palette.text)
                .padding(.top, 20)
            Text("Your coding agents, from your pocket.")
                .font(Typography.body)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                step(1, String(localized: "Open Helm on your Mac."))
                step(2, String(localized: "Settings → Connections → turn on Network access."))
                step(3, String(localized: "Pair a device, then scan the code or paste the link here."))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 20)
            Button {
                router.showPairing = true
            } label: {
                Text("Connect to Helm")
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.accentForeground)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Typography.mono(13))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18)
            Text(text)
                .font(Typography.subheadline)
                .foregroundStyle(Palette.text)
        }
    }
}

/// The Helm mark: a dark rounded screen with an amber signal trace.
struct HelmMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 120
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(roundedRect: rect, cornerRadius: 26 * scale), with: .color(Color(hex: 0x26211D)))
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: 2 * scale, dy: 2 * scale), cornerRadius: 24 * scale),
                with: .color(Color(hex: 0xEFE7D6).opacity(0.18)), lineWidth: 4 * scale
            )
            var path = Path()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            path.move(to: p(26, 60))
            path.addQuadCurve(to: p(34, 60), control: p(30, 50))
            path.addQuadCurve(to: p(42, 60), control: p(38, 70))
            path.addQuadCurve(to: p(50, 60), control: p(46, 50))
            path.addQuadCurve(to: p(58, 60), control: p(54, 70))
            path.addLine(to: p(58, 47))
            path.addLine(to: p(70, 47))
            path.addLine(to: p(70, 73))
            path.addLine(to: p(82, 73))
            path.addLine(to: p(82, 60))
            path.addLine(to: p(93, 60))
            context.stroke(path, with: .color(Palette.accent),
                           style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
