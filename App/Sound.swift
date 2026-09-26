import AVFoundation
import AppKit

@MainActor
enum Sound {
    enum Cue: String {
        case whoosh, boop, ping, stamp, deny, drop, bell, ding, thunk, tick
    }

    private static var players: [Cue: [AVAudioPlayer]] = [:]
    private static var patter: AVAudioPlayer?
    private static var patterOwners: Set<ObjectIdentifier> = []

    private static var allowed: Bool { Preferences.shared.sounds && NSApp.isActive }

    static func play(_ cue: Cue, volume: Float = 1, rate: Float = 1, after delay: Duration = .zero) {
        guard allowed else { return }
        guard delay == .zero else {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                play(cue, volume: volume, rate: rate)
            }
            return
        }
        let player = players[cue, default: []].first { !$0.isPlaying } ?? makePlayer(cue)
        guard let player else { return }
        player.enableRate = rate != 1
        player.rate = rate
        player.volume = volume * Float(Preferences.shared.soundVolume)
        player.currentTime = 0
        player.play()
    }

    private static func makePlayer(_ cue: Cue) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[cue, default: []].append(player)
        return player
    }

    static func setPatter(_ on: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        let changed = on ? patterOwners.insert(id).inserted : patterOwners.remove(id) != nil
        guard changed || (on && patter?.isPlaying != true && allowed) else { return }
        if patterOwners.isEmpty || !allowed {
            patter?.pause()
            return
        }
        if patter == nil, let url = Bundle.main.url(forResource: "patter", withExtension: "m4a") {
            patter = try? AVAudioPlayer(contentsOf: url)
            patter?.numberOfLoops = -1
        }
        patter?.volume = 0.12 * Float(Preferences.shared.soundVolume)
        patter?.play()
    }
}
