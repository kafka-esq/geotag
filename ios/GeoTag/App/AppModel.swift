import SwiftUI

/// App-wide state: who you are, which screen you're on, and the one AR controller everything shares.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case loading, offline(String), onboarding, ready }

    @Published var phase: Phase = .loading
    @Published var me: Profile?
    @Published var practice = false
    @Published var toast: String?
    let ar = ARController()
    let api = SupabaseClient.shared

    private var toastTask: Task<Void, Never>?

    func boot() async {
        guard api.isConfigured else {
            phase = .offline("geo# isn't connected to a server yet. you can still try practice mode.")
            return
        }
        do {
            try await api.ensureSession()
            me = try await api.rpcOptional("me", as: Profile.self)
            phase = me == nil ? .onboarding : .ready
        } catch {
            phase = .offline(error.localizedDescription)
        }
    }

    func redeem(code: String, handle: String) async throws {
        try await api.ensureSession()
        let p: Profile = try await api.rpc("redeem_invite", ["p_code": code, "p_handle": handle])
        me = p
        practice = false
        phase = .ready
        show("you're in, \(p.handle)")
    }

    func startPractice() {
        practice = true
        phase = .ready
    }

    func leavePractice() {
        practice = false
        Task { await boot() }
    }

    func deleteAccount() async throws {
        try await api.rpcVoid("delete_account")
        await api.signOutLocally()
        me = nil
        phase = .onboarding
        show("account deleted")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
}
