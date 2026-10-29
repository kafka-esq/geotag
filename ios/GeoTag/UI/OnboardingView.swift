import SwiftUI

/// First run: what geo# is (with the required ARCore notice), the crew rules, then name + crew code.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("geo.privacyAck") private var privacyAck = false
    @State private var step = 0
    @State private var agreed = false
    @State private var handle = ""
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            BrickBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GraffitiTitle(size: 120)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    switch step {
                    case 0: intro
                    case 1: rules
                    default: gate
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            if privacyAck { step = 1 }
            #if DEBUG
            let forced = UserDefaults.standard.integer(forKey: "geoStep")
            if forced > 0 { step = forced; agreed = forced > 1 }
            #endif
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("every wall in the city is a canvas. only your crew can see it.")
                .font(Theme.body(26, .heavy)).foregroundStyle(Theme.chalk)
            bullet("spray", "your phone is the can. aim the camera, hold, move.")
            bullet("layer", "go over what's there. newest paint sits on top.")
            bullet("find", "the map shows every painted wall near you.")
            Text("geo# runs on Google Play Services for AR (ARCore), provided by Google LLC and governed by the Google Privacy Policy.")
                .font(Theme.body(13)).foregroundStyle(Theme.mute)
            Link("how google uses data when you use partner apps", destination: URL(string: "https://www.google.com/policies/privacy/partners/")!)
                .font(Theme.body(13, .semibold))
            Button { privacyAck = true; step = 1 } label: {
                Text("continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChalkButton(fill: Theme.paint))
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("crew rules").font(Theme.display(44)).foregroundStyle(Theme.chalk)
            Text("geo# has zero tolerance for abuse. break these and you're out, and so might the people you invited.")
                .font(Theme.body(16)).foregroundStyle(Theme.chalk)
            rule("no hate, slurs, threats or harassment")
            rule("no sexual content, no gore")
            rule("no names, addresses or faces of real people without their ok")
            rule("no painting over a piece just to wreck it. going over is part of the game; erasing someone is not")
            rule("geo# is digital only. don't paint real walls")
            rule("report anything that breaks these. we act on reports within 24 hours")
            Link("full terms of use", destination: URL(string: Secrets.siteURL + "/terms.html")!)
                .font(Theme.body(14, .semibold))
            Toggle(isOn: $agreed) { Text("i agree to the terms and crew rules").font(Theme.body(15, .semibold)) }
                .tint(Theme.paint)
            Button { step = 2 } label: { Text("continue").frame(maxWidth: .infinity) }
                .buttonStyle(ChalkButton(fill: agreed ? Theme.paint : Theme.panel))
                .disabled(!agreed)
        }
    }

    private var gate: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("you need a crew code to get in.")
                .font(Theme.body(22, .heavy)).foregroundStyle(Theme.chalk)
            label("your tag name")
            TextField("@kafka_esq", text: $handle)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14).background(Theme.ink.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.chalk, lineWidth: 2))
            label("crew code")
            TextField("from whoever invited you", text: $code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .padding(14).background(Theme.ink.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.chalk, lineWidth: 2))
            if let error {
                Text(error).font(Theme.body(15, .semibold)).foregroundStyle(Theme.cap)
            }
            Button {
                Task { await submit() }
            } label: {
                Group { if busy { ProgressView() } else { Text("get in").font(Theme.display(34)) } }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(ChalkButton(fill: Theme.paint))
            .disabled(busy)
            Button("no code? try practice mode") { model.startPractice() }
                .font(Theme.body(15, .semibold)).foregroundStyle(Theme.chalk)
                .frame(maxWidth: .infinity).padding(.top, 6)
        }
    }

    private func submit() async {
        let h = handle.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        guard h.count >= 2, c.count >= 3 else { error = "fill in both"; return }
        busy = true; error = nil
        defer { busy = false }
        do { try await model.redeem(code: c, handle: h) }
        catch { self.error = error.localizedDescription }
    }

    private func bullet(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).font(Theme.display(26)).foregroundStyle(Theme.paint).frame(width: 74, alignment: .leading)
            Text(v).font(Theme.body(16)).foregroundStyle(Theme.chalk)
        }
    }

    private func rule(_ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("✕").font(Theme.body(14, .bold)).foregroundStyle(Theme.paint)
            Text(t).font(Theme.body(15)).foregroundStyle(Theme.chalk)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(Theme.mono(12)).tracking(1).foregroundStyle(Theme.mute)
    }
}

/// Dark brick, drawn rather than shipped as an image.
struct BrickBackground: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x1E1416)))
            var g = SplitMix(seed: 11)
            let bw: CGFloat = 64, bh: CGFloat = 30
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : -bw / 2
                while x < size.width {
                    let l = 0.10 + Double(g.next()) * 0.05
                    ctx.fill(Path(roundedRect: CGRect(x: x + 2, y: y + 2, width: bw - 4, height: bh - 4), cornerRadius: 2),
                             with: .color(Color(.sRGB, red: l + 0.05, green: l - 0.01, blue: l, opacity: 1)))
                    x += bw
                }
                y += bh; row += 1
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [.clear, Theme.ink.opacity(0.85)]),
                                           center: CGPoint(x: size.width / 2, y: size.height * 0.35),
                                           startRadius: 40, endRadius: max(size.width, size.height) * 0.8))
        }
    }
}
