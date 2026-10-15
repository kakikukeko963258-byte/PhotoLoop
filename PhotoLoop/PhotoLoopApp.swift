import SwiftUI
import AVFoundation
import MediaPlayer

struct Track: Decodable, Identifiable {
    let id: Int
    let title: String
    let sections: [String]
    var text: String { sections.joined(separator: "\n\n") }
}

@main
struct PhotoLoopApp: App {
    @StateObject private var audio = AudioModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(audio) } }
}

final class AudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = []
    @Published var selected = 0
    @Published var playing = false
    @Published var generating = false
    @Published var message = "写真を選んで再生してください"
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var speed: Float = 1 { didSet { player?.rate = speed; nowPlaying() } }
    @Published var looping = true { didSet { player?.numberOfLoops = looping ? -1 : 0 } }
    @Published var deadline: Date?
    @Published var remaining = 0
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var tick: Timer?
    private var renderError: Error?
    private var generationTimedOut = false
    private var interruption: NSObjectProtocol?
    private var routeChange: NSObjectProtocol?
    var track: Track? { tracks.indices.contains(selected) ? tracks[selected] : nil }

    override init() {
        super.init()
        do {
            guard let url = Bundle.main.url(forResource: "tracks", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
            tracks = try JSONDecoder().decode([Track].self, from: Data(contentsOf: url))
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        } catch { message = "初期化できません: \(error.localizedDescription)" }
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
        }
        routeChange = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }; return .success
        }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }; return .success
        }
    }

    func choose(_ index: Int) {
        guard !generating, index != selected else { return }
        pause(); player = nil; selected = index; position = 0; duration = 0
        message = "写真\(index + 1)を選択しました"
    }
    func play() {
        guard !generating, let track = track else { return }
        if let player = player {
            if let deadline = deadline, deadline <= Date() { self.deadline = nil; remaining = 0 }
            do { try AVAudioSession.sharedInstance().setActive(true) }
            catch { message = error.localizedDescription; return }
            if player.currentTime >= player.duration { player.currentTime = 0 }
            playing = player.play(); nowPlaying(); return
        }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-\(track.id)-v1.caf")
        if FileManager.default.fileExists(atPath: url.path) { load(url); return }
        generating = true; message = "写真\(track.id)の音声を作成中…初回のみ時間がかかります"
        generationTimedOut = false
        file = nil; renderError = nil
        let utterance = AVSpeechUtterance(string: track.text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // Consume buffers before returning from Apple's callback.
            let consume = {
                guard let self = self else { return }
                if pcm.frameLength == 0 {
                    self.file = nil; self.generating = false
                    if let error = self.renderError {
                        try? FileManager.default.removeItem(at: url)
                        self.message = "音声作成に失敗: \(error.localizedDescription)"
                    } else { self.load(url) }
                } else if self.renderError == nil {
                    do {
                        if self.file == nil { self.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                        try self.file?.write(from: pcm)
                    } catch { self.renderError = error }
                }
            }
            if Thread.isMainThread { consume() } else { DispatchQueue.main.sync(execute: consume) }
        }
    }
    private func load(_ url: URL) {
        do {
            let result = try AVAudioPlayer(contentsOf: url)
            guard result.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            player = result; result.delegate = self; result.enableRate = true
            result.rate = speed; result.numberOfLoops = looping ? -1 : 0
            duration = result.duration; message = "音声の準備ができました"
            if generationTimedOut { message = "スリープタイマーで停止しました"; generationTimedOut = false }
            else { play() }
        } catch {
            try? FileManager.default.removeItem(at: url)
            message = "音声を読み込めません。もう一度再生してください。\(error.localizedDescription)"
        }
    }
    func pause() { player?.pause(); playing = false; nowPlaying() }
    func seek(_ seconds: Double) {
        guard let player = player else { return }
        player.currentTime = min(max(0, seconds), player.duration); position = player.currentTime; nowPlaying()
    }
    func setTimer(_ minutes: Int) {
        deadline = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        remaining = minutes * 60
    }
    private func update() {
        if let deadline = deadline {
            remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            if deadline <= Date() {
                if generating { generationTimedOut = true }
                pause(); self.deadline = nil; message = "スリープタイマーで停止しました"
            }
        }
        position = player?.currentTime ?? 0
    }
    private func nowPlaying() {
        guard let track = track else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "写真\(track.id) · \(track.title)",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0
        ]
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { playing = false; nowPlaying() }
}

struct ContentView: View {
    @EnvironmentObject var audio: AudioModel
    @State private var timerMinutes = 30
    private func clock(_ value: Double) -> String { let n = max(0, Int(value)); return String(format: "%d:%02d", n / 60, n % 60) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("ENGLISH LISTENING").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.secondary)
                    Text("写真の英文を、\n何度でも。").font(.largeTitle.bold())
                    ForEach(Array(audio.tracks.enumerated()), id: \.element.id) { index, track in
                        Button { audio.choose(index) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: ["moon.stars.fill", "bird.fill", "airplane"][index]).font(.title2).frame(width: 36)
                                VStack(alignment: .leading) {
                                    Text("写真\(track.id)").font(.caption)
                                    Text(track.title).font(.headline)
                                    Text("1〜4節をまとめて再生").font(.caption).opacity(0.7)
                                }
                                Spacer()
                                if audio.selected == index { Image(systemName: "checkmark.circle.fill") }
                            }.padding().background(audio.selected == index ? Color.indigo.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).disabled(audio.generating)
                    }
                    VStack(spacing: 15) {
                        Text(audio.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        if audio.generating { ProgressView() }
                        Slider(value: Binding(get: { audio.position }, set: { audio.seek($0) }), in: 0...max(1, audio.duration)).disabled(audio.duration == 0)
                        HStack { Text(clock(audio.position)); Spacer(); Text(clock(audio.duration)) }.font(.caption.monospacedDigit())
                        HStack(spacing: 35) {
                            Button { audio.seek(audio.position - 15) } label: { Image(systemName: "gobackward.15").font(.title) }
                            Button { audio.playing ? audio.pause() : audio.play() } label: { Image(systemName: audio.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 66)) }.disabled(audio.generating)
                            Button { audio.seek(audio.position + 15) } label: { Image(systemName: "goforward.15").font(.title) }
                        }.accessibilityElement(children: .contain)
                        Toggle("この写真をループ再生", isOn: $audio.looping)
                        HStack {
                            Text("再生速度"); Spacer()
                            Picker("再生速度", selection: $audio.speed) {
                                ForEach([Float(0.7), 0.85, 1, 1.15, 1.3], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                            }
                        }
                    }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    VStack(alignment: .leading, spacing: 12) {
                        Label("スリープタイマー", systemImage: "moon.zzz.fill").font(.headline)
                        Stepper("\(timerMinutes)分後に停止", value: $timerMinutes, in: 1...180)
                        HStack {
                            Button("タイマー開始") { audio.setTimer(timerMinutes) }.buttonStyle(.borderedProminent)
                            if audio.deadline != nil { Button("解除") { audio.setTimer(0) } }
                        }
                        if audio.deadline != nil { Text("残り \(clock(Double(audio.remaining)))").monospacedDigit() }
                    }.padding().background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                    if let track = audio.track {
                        DisclosureGroup("英文を見る · 写真\(track.id)") {
                            ForEach(Array(track.sections.enumerated()), id: \.offset) { index, text in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("SECTION \(index + 1)").font(.caption.bold()).foregroundStyle(.indigo)
                                    Text(text).font(.body).lineSpacing(6).textSelection(.enabled)
                                }.padding(.vertical)
                            }
                        }
                    }
                    Text("初回は画面を開いたまま音声の作成完了をお待ちください。作成後はオフライン・画面ロック中も再生できます。").font(.footnote).foregroundStyle(.secondary)
                }.padding(22)
            }.navigationTitle("写真リスニング").navigationBarTitleDisplayMode(.inline).tint(.indigo)
        }
    }
}
