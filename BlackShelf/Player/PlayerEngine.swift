import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum SleepTimer: Equatable {
  case off
  case until(Date)
  case endOfChapter
}

/// Hörbuch-Wiedergabe mit Audiobookshelf-Wiedergabesitzungen.
/// Ein Buch kann aus mehreren Audiodateien bestehen – nach außen gibt es nur eine durchgehende Zeitachse.
@Observable
@MainActor
final class PlayerEngine {
  static let shared = PlayerEngine()

  private(set) var item: ABSItem?
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  private(set) var isStarting = false
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  private(set) var chapters: [ABSChapter] = []
  private(set) var sleepTimer: SleepTimer = .off
  var errorMessage: String?
  /// Vollbild-Player sichtbar
  var isPresented = false

  var rate: Float = UserDefaults.standard.object(forKey: "player.rate") as? Float ?? 1.0 {
    didSet {
      UserDefaults.standard.set(rate, forKey: "player.rate")
      if isPlaying { player.rate = rate }
      player.defaultRate = rate
      updateNowPlaying()
    }
  }

  var skipBackInterval: Double = UserDefaults.standard.object(forKey: "player.skipBack") as? Double ?? 15 {
    didSet { UserDefaults.standard.set(skipBackInterval, forKey: "player.skipBack"); configureSkipIntervals() }
  }

  var skipForwardInterval: Double = UserDefaults.standard.object(forKey: "player.skipForward") as? Double ?? 30 {
    didSet { UserDefaults.standard.set(skipForwardInterval, forKey: "player.skipForward"); configureSkipIntervals() }
  }

  @ObservationIgnored weak var app: AppModel?

  private let client = ABSClient.shared
  private let player = AVPlayer()
  private var session: ABSPlaySession?
  private var tracks: [ABSTrack] = []
  private var trackIndex = 0
  private var pendingSeek: Double?
  private var pendingPlay = false
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
  @ObservationIgnored private var lastTick: Date?
  @ObservationIgnored private var listenedSinceSync: Double = 0
  @ObservationIgnored private var lastSync = Date()
  private var lastChapterId: Int?
  @ObservationIgnored private var artwork: MPMediaItemArtwork?
  private var reloadAttempted = false
  private var wasPlayingBeforeInterruption = false

  private init() {
    player.automaticallyWaitsToMinimizeStalling = true
    player.defaultRate = rate
    configureAudioSession()
    configureRemoteCommands()
    observePlayer()
  }

  // MARK: Abgeleitete Werte

  var hasItem: Bool { item != nil }

  var currentChapter: ABSChapter? {
    chapters.first { currentTime >= $0.start && currentTime < $0.end } ?? chapters.last { currentTime >= $0.start }
  }

  var currentChapterIndex: Int? {
    guard let c = currentChapter else { return nil }
    return chapters.firstIndex(of: c)
  }

  /// Verbleibende Zeit im Buch, bezogen auf die aktuelle Geschwindigkeit
  var remainingAtRate: Double { max(0, duration - currentTime) / Double(max(rate, 0.1)) }

  // MARK: Laden & Starten

  /// Startet ein Buch. Läuft es bereits, wird nur gesprungen bzw. fortgesetzt.
  func play(_ newItem: ABSItem, from start: Double? = nil) async {
    if newItem.id == item?.id, session != nil {
      if let start { seek(to: start) }
      play()
      return
    }
    await closeSession()
    errorMessage = nil
    isStarting = true
    defer { isStarting = false }

    item = newItem
    chapters = newItem.media.chapters ?? []
    duration = newItem.duration
    currentTime = start ?? app?.progress(for: newItem.id)?.currentTime ?? 0
    loadArtwork(for: newItem)

    do {
      let s = try await client.startPlayback(newItem.id)
      guard item?.id == newItem.id else { return }
      session = s
      tracks = s.audioTracks
      guard !tracks.isEmpty else {
        errorMessage = "Für dieses Hörbuch wurden keine abspielbaren Audiodateien gefunden."
        return
      }
      if !s.chapters.isEmpty { chapters = s.chapters }
      duration = s.duration > 0 ? s.duration : tracks.reduce(0) { $0 + $1.duration }
      var begin = start ?? s.currentTime
      if begin >= duration - 5 { begin = 0 } // fertig gehört → von vorn
      currentTime = begin
      listenedSinceSync = 0
      lastSync = Date()
      reloadAttempted = false
      UserDefaults.standard.set(newItem.id, forKey: "player.lastItemId")
      loadTrack(at: begin, autoplay: true)
      // Vollständige Metadaten (Kapitel, Sprecher …) nachladen, falls minimiert übergeben
      if newItem.media.chapters == nil, let full = try? await client.item(newItem.id), item?.id == full.id {
        item = full
        if chapters.isEmpty { chapters = full.media.chapters ?? [] }
        updateNowPlaying()
      }
    } catch {
      errorMessage = error.localizedDescription
      isPlaying = false
    }
  }

  /// Zuletzt gehörtes Buch nach App-Start im Mini-Player bereitstellen (ohne Wiedergabe)
  func restoreLastItem() async {
    guard item == nil, let id = UserDefaults.standard.string(forKey: "player.lastItemId"),
          let it = try? await client.item(id), item == nil else { return }
    item = it
    chapters = it.media.chapters ?? []
    duration = it.duration
    currentTime = it.userMediaProgress?.currentTime ?? app?.progress(for: id)?.currentTime ?? 0
    loadArtwork(for: it)
    updateNowPlaying()
  }

  private func indexOfTrack(at global: Double) -> Int {
    tracks.lastIndex { global >= $0.startOffset - 0.001 } ?? 0
  }

  private func loadTrack(at global: Double, autoplay: Bool) {
    let idx = indexOfTrack(at: global)
    guard tracks.indices.contains(idx), let url = client.streamURL(tracks[idx].contentUrl) else {
      errorMessage = "Stream-Adresse ungültig."
      return
    }
    trackIndex = idx
    var headers: [String: String] = [:]
    if let t = client.accessToken { headers["Authorization"] = "Bearer \(t)" }
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    let playerItem = AVPlayerItem(asset: asset)
    playerItem.audioTimePitchAlgorithm = .timeDomain
    playerItem.preferredForwardBufferDuration = 30

    pendingSeek = max(0, global - tracks[idx].startOffset)
    pendingPlay = autoplay
    statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] obj, _ in
      let status = obj.status
      let message = obj.error?.localizedDescription
      Task { @MainActor in self?.itemStatusChanged(status, error: message) }
    }
    player.replaceCurrentItem(with: playerItem)
    if autoplay { isBuffering = true }
  }

  private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?) {
    switch status {
    case .readyToPlay:
      reloadAttempted = false
      if let s = pendingSeek {
        pendingSeek = nil
        let shouldPlay = pendingPlay
        player.seek(to: CMTime(seconds: s, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
          Task { @MainActor in
            if shouldPlay { self?.play() }
          }
        }
      } else if pendingPlay {
        play()
      }
      pendingPlay = false
    case .failed:
      let resumeAt = currentTime
      let wasPlaying = isPlaying || pendingPlay
      if !reloadAttempted {
        // häufigste Ursache: Token abgelaufen → erneuern und an gleicher Stelle neu laden
        reloadAttempted = true
        Task {
          _ = await client.refreshAccessToken()
          loadTrack(at: resumeAt, autoplay: wasPlaying)
        }
      } else {
        isPlaying = false
        isBuffering = false
        errorMessage = error ?? "Wiedergabe fehlgeschlagen."
      }
    default:
      break
    }
  }

  // MARK: Steuerung

  func play() {
    guard let item else { return }
    if session == nil {
      Task { await play(item, from: currentTime) }
      return
    }
    if player.currentItem == nil {
      loadTrack(at: currentTime, autoplay: true)
      return
    }
    activateAudioSession()
    player.volume = 1
    player.playImmediately(atRate: rate)
    isPlaying = true
    lastTick = Date()
    updateNowPlaying()
  }

  func pause() {
    accumulateListening()
    player.pause()
    isPlaying = false
    lastTick = nil
    updateNowPlaying()
    sync()
  }

  func togglePlayPause() { isPlaying ? pause() : play() }

  func seek(to global: Double) {
    let target = min(max(0, global), max(0, duration - 0.5))
    currentTime = target
    guard session != nil, !tracks.isEmpty else { updateNowPlaying(); return }
    let idx = indexOfTrack(at: target)
    if idx == trackIndex, player.currentItem != nil {
      let local = target - tracks[idx].startOffset
      player.seek(to: CMTime(seconds: local, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    } else {
      loadTrack(at: target, autoplay: isPlaying)
    }
    updateNowPlaying()
  }

  func skip(by delta: Double) { seek(to: currentTime + delta) }
  func skipBack() { skip(by: -skipBackInterval) }
  func skipForward() { skip(by: skipForwardInterval) }

  func nextChapter() {
    guard let i = currentChapterIndex, chapters.indices.contains(i + 1) else { return }
    seek(to: chapters[i + 1].start)
  }

  func previousChapter() {
    guard let i = currentChapterIndex else { seek(to: 0); return }
    // wie bei Musik: erst an den Kapitelanfang, bei erneutem Tippen ins vorige Kapitel
    if currentTime - chapters[i].start > 3 || i == 0 {
      seek(to: chapters[i].start)
    } else {
      seek(to: chapters[i - 1].start)
    }
  }

  func setSleepTimer(_ timer: SleepTimer) {
    sleepTimer = timer
    player.volume = 1
  }

  /// Wiedergabe beenden und Mini-Player schließen
  func stop() async {
    pause()
    await closeSession()
    player.replaceCurrentItem(with: nil)
    item = nil
    chapters = []
    sleepTimer = .off
    UserDefaults.standard.removeObject(forKey: "player.lastItemId")
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // MARK: Fortschritt

  private func tick() {
    guard session != nil, tracks.indices.contains(trackIndex) else { return }
    let local = player.currentTime().seconds
    if local.isFinite, pendingSeek == nil {
      currentTime = tracks[trackIndex].startOffset + local
    }
    if isPlaying { accumulateListening() }

    if Date().timeIntervalSince(lastSync) >= 15 { sync() }
    checkSleepTimer()

    if let c = currentChapter?.id, c != lastChapterId {
      lastChapterId = c
      updateNowPlaying()
    }
  }

  private func accumulateListening() {
    let now = Date()
    if let last = lastTick { listenedSinceSync += min(now.timeIntervalSince(last), 2) }
    lastTick = isPlaying ? now : nil
  }

  /// Fortschritt an Audiobookshelf melden
  func sync() {
    guard let s = session, let item else { return }
    let listened = listenedSinceSync
    listenedSinceSync = 0
    lastSync = Date()
    let time = currentTime, dur = duration
    app?.updateLocalProgress(itemId: item.id, currentTime: time, duration: dur)
    Task {
      do {
        try await client.syncSession(s.id, currentTime: time, timeListened: listened, duration: dur)
      } catch {
        listenedSinceSync += listened // beim nächsten Mal erneut melden
      }
    }
  }

  private func closeSession() async {
    guard let s = session else { return }
    accumulateListening()
    let listened = listenedSinceSync
    listenedSinceSync = 0
    session = nil
    try? await client.closeSession(s.id, currentTime: currentTime, timeListened: listened, duration: duration)
    await app?.refreshProgress()
  }

  private func trackDidEnd() {
    if tracks.indices.contains(trackIndex + 1) {
      loadTrack(at: tracks[trackIndex + 1].startOffset, autoplay: true)
      return
    }
    // Buch zu Ende
    accumulateListening()
    currentTime = duration
    isPlaying = false
    lastTick = nil
    sleepTimer = .off
    sync()
    updateNowPlaying()
    Task {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      await app?.refreshProgress()
    }
  }

  private func checkSleepTimer() {
    switch sleepTimer {
    case .off:
      return
    case let .until(date):
      let remaining = date.timeIntervalSinceNow
      if remaining <= 0 {
        sleepTimer = .off
        pause()
        player.volume = 1
      } else if remaining < 10, isPlaying {
        player.volume = Float(remaining / 10) // sanft ausblenden
      }
    case .endOfChapter:
      if let c = currentChapter, c.end - currentTime < 0.6, isPlaying {
        sleepTimer = .off
        pause()
      }
    }
  }

  var sleepTimerRemaining: TimeInterval? {
    switch sleepTimer {
    case .off: return nil
    case let .until(d): return max(0, d.timeIntervalSinceNow)
    case .endOfChapter: return currentChapter.map { max(0, $0.end - currentTime) / Double(rate) }
    }
  }

  // MARK: Audio-Session & Benachrichtigungen

  private func configureAudioSession() {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
  }

  private func activateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  private func observePlayer() {
    player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
      let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
      let playing = p.timeControlStatus == .playing
      Task { @MainActor in
        guard let self else { return }
        self.isBuffering = waiting
        if playing { self.isBuffering = false }
      }
    }
    let nc = NotificationCenter.default
    nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
      let ended = note.object as AnyObject?
      MainActor.assumeIsolated {
        guard let self, ended === self.player.currentItem else { return }
        self.trackDidEnd()
      }
    }
    nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      let info = note.userInfo
      MainActor.assumeIsolated { self?.handleInterruption(info) }
    }
    nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
      MainActor.assumeIsolated {
        // Kopfhörer abgezogen → pausieren (HIG/Apple-Verhalten)
        if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.pause() }
      }
    }
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.sync() }
    }
  }

  private func handleInterruption(_ info: [AnyHashable: Any]?) {
    guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      wasPlayingBeforeInterruption = isPlaying
      if isPlaying {
        accumulateListening()
        isPlaying = false
        sync()
        updateNowPlaying()
      }
    case .ended:
      let opts = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
      if wasPlayingBeforeInterruption, opts.contains(.shouldResume) {
        skip(by: -2) // kurzer Rücksprung, damit nichts verloren geht
        play()
      }
      wasPlayingBeforeInterruption = false
    @unknown default:
      break
    }
  }

  // MARK: Sperrbildschirm & Kontrollzentrum

  private func configureRemoteCommands() {
    let rc = MPRemoteCommandCenter.shared()
    rc.playCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.play() }
      return .success
    }
    rc.pauseCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.pause() }
      return .success
    }
    rc.togglePlayPauseCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.togglePlayPause() }
      return .success
    }
    rc.skipBackwardCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.skipBack() }
      return .success
    }
    rc.skipForwardCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.skipForward() }
      return .success
    }
    rc.nextTrackCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.nextChapter() }
      return .success
    }
    rc.previousTrackCommand.addTarget { [weak self] _ in
      MainActor.assumeIsolated { self?.previousChapter() }
      return .success
    }
    rc.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let pos = e.positionTime
      MainActor.assumeIsolated {
        guard let self else { return }
        // Sperrbildschirm zeigt das aktuelle Kapitel
        self.seek(to: (self.currentChapter?.start ?? 0) + pos)
      }
      return .success
    }
    rc.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    rc.changePlaybackRateCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
      let r = e.playbackRate
      MainActor.assumeIsolated { self?.rate = r }
      return .success
    }
    // Vor/Zurück-Tasten des Sperrbildschirms als Sprungtasten (wie Apple Bücher)
    rc.nextTrackCommand.isEnabled = false
    rc.previousTrackCommand.isEnabled = false
    configureSkipIntervals()
  }

  private func configureSkipIntervals() {
    let rc = MPRemoteCommandCenter.shared()
    rc.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackInterval)]
    rc.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
  }

  private func loadArtwork(for book: ABSItem) {
    artwork = nil
    let itemId = book.id
    guard let url = AudibleCovers.shared.url(for: book, width: 1024) else { return }
    Task {
      guard let result = try? await URLSession.shared.data(from: url),
            let image = UIImage(data: result.0), item?.id == itemId else { return }
      artwork = Self.makeArtwork(image)
      updateNowPlaying()
    }
  }

  /// Außerhalb des MainActors erzeugen – MediaPlayer ruft den Block auf einem Hintergrund-Thread auf
  nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }

  private func updateNowPlaying() {
    guard let item else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyAlbumTitle: item.title,
      MPMediaItemPropertyArtist: item.author,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
    ]
    if let c = currentChapter, chapters.count > 1 {
      info[MPMediaItemPropertyTitle] = c.title.isEmpty ? item.title : c.title
      info[MPMediaItemPropertyPlaybackDuration] = c.duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime - c.start)
      if let i = currentChapterIndex {
        info[MPNowPlayingInfoPropertyChapterNumber] = i
        info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
      }
    } else {
      info[MPMediaItemPropertyTitle] = item.title
      info[MPMediaItemPropertyPlaybackDuration] = duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }
}
