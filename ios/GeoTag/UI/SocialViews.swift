import MapKit
import SwiftUI

/// Renders pieces flat, for sheets and the map (no AR needed).
enum PieceRender {
    static func image(_ pieces: [PieceDTO], maxPixels: Int = 1400) -> CGImage? {
        guard !pieces.isEmpty else { return nil }
        let x0 = pieces.map(\.x0).min()! - 0.25, y0 = pieces.map(\.y0).min()! - 0.25
        let x1 = pieces.map(\.x1).max()! + 0.25, y1 = pieces.map(\.y1).max()! + 0.25
        let w = max(0.5, x1 - x0), h = max(0.5, y1 - y0)
        let ppm = min(140, Float(maxPixels) / max(w, h))
        let r = WallRaster(canvasX0: x0, canvasY0: y0, canvasW: w, canvasH: h, pxPerMetre: ppm)
        for p in pieces { r.draw(p.data) }
        return r.cgImage()
    }
}

struct WallImage: View {
    let image: CGImage?
    var body: some View {
        ZStack {
            BrickBackground()
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
            } else {
                ProgressView().tint(Theme.chalk)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: piece

struct PieceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var piece: PieceDTO
    var openWall: () -> Void

    @State private var image: CGImage?
    @State private var comments: [CommentDTO] = []
    @State private var draft = ""
    @State private var showProfile: String?
    @State private var reportOpen = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WallImage(image: image).frame(height: 240)
                    HStack {
                        Button { if let h = piece.handle { showProfile = h } } label: {
                            Text(piece.handle ?? "you").font(Theme.body(22, .heavy)).foregroundStyle(Theme.chalk)
                        }
                        Spacer()
                        Text("\(piece.kind) · \(Fmt.ago(piece.created_at))").font(Theme.mono(12)).foregroundStyle(Theme.mute)
                    }
                    HStack(spacing: 10) {
                        Button { Task { await prop() } } label: {
                            Label("\(piece.props_count)", systemImage: piece.i_propped == true ? "flame.fill" : "flame")
                        }
                        .buttonStyle(ChalkButton(fill: piece.i_propped == true ? Theme.paint : Theme.panel))
                        Button("whole wall", action: openWall).buttonStyle(ChalkButton())
                        Spacer()
                        Menu {
                            if piece.mine == true {
                                Button("delete this piece", role: .destructive) { confirmDelete = true }
                            } else {
                                Button("report this piece") { reportOpen = true }
                                if let a = piece.author_id {
                                    Button("block \(piece.handle ?? "them")", role: .destructive) { Task { await block(a) } }
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(Theme.chalk) }
                    }
                    Divider().overlay(Theme.line)
                    Text("comments").font(Theme.display(28)).foregroundStyle(Theme.chalk)
                    if comments.isEmpty {
                        Text("no comments yet. say something.").font(Theme.body(15)).foregroundStyle(Theme.mute)
                    }
                    ForEach(comments) { c in CommentRow(comment: c, reload: { await load() }, showProfile: { showProfile = $0 }) }
                }
                .padding(18)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    TextField("leave a comment", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(12).background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                    Button("post") { Task { await comment() } }
                        .buttonStyle(ChalkButton(fill: Theme.paint)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12).background(Theme.sheet)
            }
            .background(Theme.sheet)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
            .sheet(item: Binding(get: { showProfile.map { HandleRef(handle: $0) } }, set: { showProfile = $0?.handle })) { ref in
                ProfileCardView(handle: ref.handle)
            }
            .sheet(isPresented: $reportOpen) {
                ReportView(title: "report this piece") { reason in
                    try await SupabaseClient.shared.rpcVoid("report", ["p_piece": piece.id, "p_reason": reason])
                    model.show("reported. thanks for keeping it clean")
                }
            }
            .confirmationDialog("delete this piece?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("delete", role: .destructive) { Task { await delete() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            image = PieceRender.image([piece])
            await load()
        }
    }

    private func load() async {
        comments = (try? await SupabaseClient.shared.rpc("piece_comments", ["p_piece": piece.id], as: [CommentDTO].self)) ?? comments
    }

    private func prop() async {
        do {
            let n: Int = try await SupabaseClient.shared.rpc("toggle_prop", ["p_piece": piece.id])
            piece.i_propped = n > piece.props_count ? true : (n < piece.props_count ? false : !(piece.i_propped ?? false))
            piece.props_count = n
        } catch { model.show(error.localizedDescription) }
    }

    private func comment() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            try await SupabaseClient.shared.rpcVoid("add_comment", ["p_piece": piece.id, "p_body": body])
            draft = ""
            await load()
        } catch { model.show(error.localizedDescription) }
    }

    private func block(_ id: String) async {
        do {
            try await SupabaseClient.shared.rpcVoid("block_user", ["p_user": id])
            model.ar.store.refreshNow()
            for w in model.ar.store.all { w.piecesLoadedAt = nil }
            model.show("blocked. you won't see their art or comments")
            dismiss()
        } catch { model.show(error.localizedDescription) }
    }

    private func delete() async {
        do {
            try await SupabaseClient.shared.rpcVoid("delete_my_piece", ["p_piece": piece.id])
            if let w = model.ar.store.walls[piece.wall_id] {
                w.pieces.removeAll { $0.id == piece.id }
                w.rebuildRaster()
            }
            model.show("piece deleted")
            dismiss()
        } catch { model.show(error.localizedDescription) }
    }
}

struct HandleRef: Identifiable { let handle: String; var id: String { handle } }

struct CommentRow: View {
    @EnvironmentObject var model: AppModel
    let comment: CommentDTO
    let reload: () async -> Void
    let showProfile: (String) -> Void
    @State private var reporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(comment.handle) { showProfile(comment.handle) }
                    .font(Theme.body(15, .bold)).foregroundStyle(Theme.chalk)
                Text(Fmt.ago(comment.created_at)).font(Theme.mono(11)).foregroundStyle(Theme.mute)
                Spacer()
                Menu {
                    if comment.mine {
                        Button("delete", role: .destructive) {
                            Task { try? await SupabaseClient.shared.rpcVoid("delete_my_comment", ["p_comment": comment.id]); await reload() }
                        }
                    } else {
                        Button("report comment") { reporting = true }
                        Button("block \(comment.handle)", role: .destructive) {
                            Task {
                                try? await SupabaseClient.shared.rpcVoid("block_user", ["p_user": comment.author_id])
                                model.show("blocked")
                                await reload()
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.mute).padding(6) }
            }
            Text(comment.body).font(Theme.body(15)).foregroundStyle(Theme.chalk)
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $reporting) {
            ReportView(title: "report comment") { reason in
                try await SupabaseClient.shared.rpcVoid("report", ["p_comment": comment.id, "p_reason": reason])
                model.show("reported")
                await reload()
            }
        }
    }
}

struct ReportView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let send: (String) async throws -> Void
    @State private var reason = "hate or harassment"
    @State private var note = ""
    @State private var error: String?
    private let reasons = ["hate or harassment", "sexual content", "violence or threats", "personal info about someone",
                           "spam", "wrecking someone's piece on purpose", "something else"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("what's wrong", selection: $reason) { ForEach(reasons, id: \.self) { Text($0) } }
                    .pickerStyle(.inline)
                TextField("anything we should know (optional)", text: $note, axis: .vertical)
                if let error { Text(error).foregroundStyle(Theme.cap) }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("send") {
                        Task {
                            do { try await send(note.isEmpty ? reason : "\(reason): \(note)"); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: wall

struct WallDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let wallId: String
    @State private var pieces: [PieceDTO] = []
    @State private var image: CGImage?
    @State private var loaded = false
    @State private var open: PieceDTO?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WallImage(image: image).frame(height: 260).listRowInsets(EdgeInsets())
                }
                Section(pieces.isEmpty && loaded ? "nothing here anymore" : "\(pieces.count) layers, newest on top") {
                    ForEach(pieces.reversed()) { p in
                        Button { open = p } label: {
                            HStack {
                                Text(p.handle ?? "you").font(Theme.body(16, .semibold)).foregroundStyle(Theme.chalk)
                                Text(p.kind).font(Theme.mono(11)).foregroundStyle(Theme.mute)
                                Spacer()
                                Label("\(p.props_count)", systemImage: "flame").font(Theme.mono(12)).foregroundStyle(Theme.mute)
                                Text(Fmt.ago(p.created_at)).font(Theme.mono(12)).foregroundStyle(Theme.mute)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("wall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
            .sheet(item: $open) { p in PieceSheet(piece: p) {} }
        }
        .task {
            do {
                pieces = try await SupabaseClient.shared.rpc("wall_pieces", ["p_wall": wallId])
                image = PieceRender.image(pieces)
            } catch { model.show(error.localizedDescription) }
            loaded = true
        }
    }
}

// MARK: map

struct MapScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var openWall: (String) -> Void
    @State private var walls: [MapWall] = []
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapWall?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(walls) { w in
                        Annotation(w.last_artist ?? "", coordinate: w.coordinate) {
                            Button { selected = w } label: {
                                Text("#").font(Theme.display(20)).foregroundStyle(Theme.chalk)
                                    .frame(width: 34, height: 34)
                                    .background(Theme.paint, in: Circle())
                                    .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                                    .overlay(alignment: .topTrailing) {
                                        if w.piece_count > 1 {
                                            Text("\(w.piece_count)").font(Theme.mono(10)).foregroundStyle(Theme.ink)
                                                .padding(3).background(Theme.cap, in: Circle()).offset(x: 6, y: -6)
                                        }
                                    }
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls { MapUserLocationButton(); MapCompass() }

                if let s = selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(s.last_artist ?? "a wall").font(Theme.body(18, .heavy)).foregroundStyle(Theme.chalk)
                            Spacer()
                            if let here = model.ar.coordinate {
                                Text(Fmt.metres(GeoMath.distance(here, s.coordinate))).font(Theme.mono(13)).foregroundStyle(Theme.mute)
                            }
                        }
                        Text("\(s.piece_count) piece\(s.piece_count == 1 ? "" : "s")\(s.last_painted_at.map { " · last paint \(Fmt.ago($0))" } ?? "")")
                            .font(Theme.body(14)).foregroundStyle(Theme.mute)
                        HStack {
                            Button("see the wall") { let id = s.id; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openWall(id) } }
                                .buttonStyle(ChalkButton(fill: Theme.paint))
                            Button("walk there") {
                                let item = MKMapItem(placemark: MKPlacemark(coordinate: s.coordinate))
                                item.name = "geo# wall"
                                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                            }
                            .buttonStyle(ChalkButton())
                        }
                    }
                    .padding(16).background(Theme.sheet, in: RoundedRectangle(cornerRadius: 16)).padding(12)
                }
            }
            .navigationTitle("walls near you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let here = model.ar.coordinate else { model.show("waiting for your location"); return }
        do {
            walls = try await SupabaseClient.shared.rpc("walls_map", ["p_lat": here.latitude, "p_lng": here.longitude, "p_radius_m": 5000])
            if walls.isEmpty { model.show("no painted walls nearby yet. be first") }
        } catch { model.show(error.localizedDescription) }
    }
}

// MARK: activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var openWall: (String) -> Void
    @State private var items: [ActivityItem] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && items.isEmpty {
                    Text("nothing yet. post something and it'll show up here.").foregroundStyle(Theme.mute)
                }
                ForEach(items) { i in
                    Button {
                        if let w = i.wall_id { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openWall(w) } }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(i.kind)).foregroundStyle(Theme.paint).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line(i)).font(Theme.body(15)).foregroundStyle(Theme.chalk)
                                if let b = i.body { Text("“\(b)”").font(Theme.body(14)).foregroundStyle(Theme.mute) }
                            }
                            Spacer()
                            Text(Fmt.ago(i.at)).font(Theme.mono(11)).foregroundStyle(Theme.mute)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private func load() async {
        items = (try? await SupabaseClient.shared.rpc("activity", as: [ActivityItem].self)) ?? items
        loaded = true
    }

    private func icon(_ k: String) -> String {
        switch k { case "prop": return "flame.fill"; case "comment": return "text.bubble.fill"; case "over": return "square.3.layers.3d"; default: return "person.badge.plus" }
    }

    private func line(_ i: ActivityItem) -> String {
        switch i.kind {
        case "prop": return "\(i.handle) gave your piece props"
        case "comment": return "\(i.handle) commented on your piece"
        case "over": return "\(i.handle) went over your piece"
        default: return "\(i.handle) joined with your crew code"
        }
    }
}
