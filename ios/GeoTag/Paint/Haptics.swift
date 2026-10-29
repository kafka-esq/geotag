import CoreHaptics
import UIKit

/// The buzz of the nozzle while spraying, the thud of a wall locking on, the tick of the rattle.
final class Haptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var running = false

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start(); self?.player = nil; self?.running = false }
        try? engine?.start()
    }

    /// Continuous buzz while the trigger is held. intensity 0...1.
    func spray(_ on: Bool, intensity: Float, sharpness: Float) {
        guard let engine else { return }
        if on && !running {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 0.5),
                .init(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0, duration: 100)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []) {
                player = try? engine.makeAdvancedPlayer(with: pattern)
                try? engine.start()
                try? player?.start(atTime: CHHapticTimeImmediate)
                running = true
            }
        } else if !on && running {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            running = false
        }
        if on, running {
            try? player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: max(0.05, min(1, intensity)), relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: max(0, min(1, sharpness)), relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        }
    }

    func thud() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    func tick() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
    func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
