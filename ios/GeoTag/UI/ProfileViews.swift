import SwiftUI

/// You: your stats, crew codes, your pieces, blocked people, rules, and account deletion.
struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var card: ProfileCard?
    @State private var invites: [InviteRow] = []
    @State private var pieces: [PieceDTO] = []
    @State private var blocked: [BlockedUser] = []
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.me?.handle ?? "").font(Theme.display(40)).foregroundStyle(Theme.chalk)
                        if let c = card {
                            HStack(spacing: 18) {
                                stat(c.pieces, "pieces"); stat(c.walls, "walls"); stat(c.props, "props"); stat(c.crew.count, "crew")
                            }
                            if let i = c.invited_by { Text("brought in by \(i)").font(Theme.body(14)).foregroundStyle(Theme.mute) }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    ForEach(invites) { inv in
                        HStack {
                            Text(inv.code).font(Theme.mono(16)).foregroundStyle(inv.used_by_handle == nil ? Theme.chalk : Theme.mute)
                            Spacer()
                            if let u = inv.used_by_handle {
                                Text("→ \(u)").font(Theme.body(14)).foregroundStyle(Theme.mute)
                            } else {
                                ShareLink(item: "join my crew on geo#. your code: \(inv.code)\n\(Secrets.siteURL)") {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                } header: { Text("your crew codes") } footer: {
                    Text("each code lets one person in. you answer for who you bring.")
                }

                Section("your pieces") {
                    if pieces.isEmpty { Text("nothing yet. go find a wall.").foregroundStyle(Theme.mute) }
                    ForEach(pieces) { p in
                        HStack {
                            Text(p.kind).font(Theme.body(15, .semibold))
                            if p.hidden == true { Text("hidden (reported)").font(Theme.mono(11)).foregroundStyle(Theme.cap) }
                            if p.archived == true { Text("wall changed").font(Theme.mono(11)).foregroundStyle(Theme.mute) }
                            Spacer()
                            Label("\(p.props_count)", systemImage: "flame").font(Theme.mono(12)).foregroundStyle(Theme.mute)
                            Text(Fmt.ago(p.created_at)).font(Theme.mono(12)).foregroundStyle(Theme.mute)
                        }
                    }
                }

                Section("blocked") {
                    if blocked.isEmpty { Text("nobody").foregroundStyle(Theme.mute) }
                    ForEach(blocked) { b in
                        HStack {
                            Text(b.handle)
                            Spacer()
                            Button("unblock") {
                                Task {
                                    try? await SupabaseClient.shared.rpcVoid("unblock_user", ["p_user": b.id])
                                    await load()
                                }
                            }
                        }
                    }
                }

                Section("geo#") {
                    Button("practice mode") { dismiss(); model.startPractice() }
                    Link("terms and crew rules", destination: URL(string: Secrets.siteURL + "/terms.html")!)
                    Link("privacy policy", destination: URL(string: Secrets.siteURL + "/privacy.html")!)
                    Link("support", destination: URL(string: Secrets.supportEmail.isEmpty ? Secrets.siteURL + "/support.html" : "mailto:\(Secrets.supportEmail)")!)
                    Text("geo# runs on Google Play Services for AR (ARCore), provided by Google LLC and governed by the Google Privacy Policy.")
                        .font(Theme.body(12)).foregroundStyle(Theme.mute)
                    Link("how google uses data when you use partner apps", destination: URL(string: "https://www.google.com/policies/privacy/partners/")!)
                }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        if deleting { ProgressView() } else { Text("delete my account") }
                    }
                } footer: {
                    Text("removes your profile, every piece you painted, your comments and props. this can't be undone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
            .confirmationDialog("delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("delete everything", role: .destructive) {
                    Task {
                        deleting = true
                        do { try await model.deleteAccount(); dismiss() } catch { model.show(error.localizedDescription) }
                        deleting = false
                    }
                }
            } message: { Text("your art comes off every wall.") }
        }
        .task { await load() }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(Theme.body(22, .heavy)).foregroundStyle(Theme.chalk)
            Text(label).font(Theme.mono(11)).foregroundStyle(Theme.mute)
        }
    }

    private func load() async {
        let api = SupabaseClient.shared
        if let h = model.me?.handle { card = try? await api.rpcOptional("profile_card", ["p_handle": h], as: ProfileCard.self) }
        invites = (try? await api.rpc("my_invites", as: [InviteRow].self)) ?? []
        pieces = (try? await api.rpc("my_pieces", as: [PieceDTO].self)) ?? []
        blocked = (try? await api.rpc("my_blocks", as: [BlockedUser].self)) ?? []
    }
}

/// Someone else: their stats and crew, plus report and block.
struct ProfileCardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let handle: String
    @State private var card: ProfileCard?
    @State private var loaded = false
    @State private var reporting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(handle).font(Theme.display(44)).foregroundStyle(Theme.chalk)
                if let c = card {
                    HStack(spacing: 22) {
                        stat(c.pieces, "pieces"); stat(c.walls, "walls"); stat(c.props, "props")
                    }
                    Text("painting since \(c.since.formatted(date: .abbreviated, time: .omitted))").font(Theme.body(14)).foregroundStyle(Theme.mute)
                    if let i = c.invited_by { Text("brought in by \(i)").font(Theme.body(14)).foregroundStyle(Theme.mute) }
                    if !c.crew.isEmpty {
                        Text("crew: " + c.crew.joined(separator: ", ")).font(Theme.body(14)).foregroundStyle(Theme.chalk)
                    }
                    HStack {
                        if c.id != model.me?.id {
                            Button(c.blocked ? "unblock" : "block") { Task { await toggleBlock(c) } }
                                .buttonStyle(ChalkButton(fill: c.blocked ? Theme.panel : Theme.paint))
                            Button("report") { reporting = true }.buttonStyle(ChalkButton())
                        }
                    }
                } else if loaded {
                    Text("can't show this person.").foregroundStyle(Theme.mute)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheet)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
            .sheet(isPresented: $reporting) {
                ReportView(title: "report \(handle)") { reason in
                    guard let id = card?.id else { return }
                    try await SupabaseClient.shared.rpcVoid("report", ["p_user": id, "p_reason": reason])
                    model.show("reported")
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            card = try? await SupabaseClient.shared.rpcOptional("profile_card", ["p_handle": handle], as: ProfileCard.self)
            loaded = true
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(Theme.body(22, .heavy)).foregroundStyle(Theme.chalk)
            Text(label).font(Theme.mono(11)).foregroundStyle(Theme.mute)
        }
    }

    private func toggleBlock(_ c: ProfileCard) async {
        do {
            try await SupabaseClient.shared.rpcVoid(c.blocked ? "unblock_user" : "block_user", ["p_user": c.id])
            card?.blocked.toggle()
            model.ar.store.refreshNow()
            for w in model.ar.store.all { w.piecesLoadedAt = nil }
            model.show(c.blocked ? "unblocked" : "blocked. you won't see their art or comments")
        } catch { model.show(error.localizedDescription) }
    }
}
