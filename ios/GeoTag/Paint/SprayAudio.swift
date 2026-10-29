import AVFoundation

/// Spray-can sound, synthesised live so there are no audio files:
/// a hiss (filtered noise) whose brightness follows distance to the wall, a sputter when pressure runs low,
/// and the ball rattle when you shake the can.
final class SprayAudio {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private var started = false

    // Written from the main thread, read on the audio thread. Plain floats are fine for this.
    private var targetGain: Float = 0
    private var brightness: Float = 0.5     // 0 = far and soft, 1 = close and harsh
    private var sputter: Float = 0
    private var rattlePending = 0

    // audio-thread state
    private var gain: Float = 0
    private var lp: Float = 0
    private var hp: Float = 0
    private var rng: UInt32 = 0x1234567
    private var rattleT: Float = 1
    private var rattleFreq: Float = 2600
    private var sputterPhase: Float = 0
    private var sampleRate: Float = 44100

    init() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = Float(format.sampleRate > 0 ? format.sampleRate : 44100)
        let mono = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        source = AVAudioSourceNode(format: mono) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let out = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(out, Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 0.9
    }

    func start() {
        guard !started else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            started = true
        } catch {
            print("geo#: audio off: \(error)")
        }
    }

    func stop() {
        engine.stop()
        started = false
    }

    /// on: trigger held with paint coming out. distance in metres. pressure 0...1.
    func update(spraying on: Bool, distance: Float, pressure: Float) {
        targetGain = on ? 0.55 : 0
        brightness = max(0, min(1, 1.2 - distance))
        sputter = on && pressure < 0.18 ? (0.18 - pressure) / 0.18 : 0
    }

    func rattle() { rattlePending += 1 }

    private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(Int32(bitPattern: rng)) / Float(Int32.max)
    }

    private func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let tg = targetGain, br = brightness, sp = sputter
        let lpCoef = 0.08 + 0.55 * br          // brighter when close
        for i in 0..<n {
            gain += (tg - gain) * 0.0015
            let w = noise()
            lp += (w - lp) * lpCoef
            hp = w - lp * 0.6                     // keep some air on top
            var s = (lp * 0.7 + hp * 0.25) * gain
            if sp > 0 {
                sputterPhase += 9 / sampleRate
                if sputterPhase > 1 { sputterPhase -= 1 }
                let gate: Float = (sin(sputterPhase * 2 * .pi * 3) + noise() * 0.6) > (1 - sp * 1.6) ? 1 : 0.15
                s *= gate
            }
            if rattleT >= 1, rattlePending > 0 {
                rattlePending = 0
                rattleT = 0
                rattleFreq = 2200 + 900 * abs(noise())
            }
            if rattleT < 1 {
                // a metal ball knocking: a short decaying ping plus a click
                let t = rattleT * 0.09
                let env = exp(-t * 60)
                s += (sin(2 * .pi * rattleFreq * t) * 0.35 + noise() * 0.25 * exp(-t * 400)) * env
                rattleT += 1 / (sampleRate * 0.09)
            }
            out[i] = max(-1, min(1, s))
        }
    }
}
