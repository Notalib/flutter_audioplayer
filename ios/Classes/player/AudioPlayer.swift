//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 26/04/15.
//  Copyright (c) 2015 Kevin Delannoy. All rights reserved.
//

import AVFoundation
#if os(iOS) || os(tvOS)
    import MediaPlayer
#endif

/// An `AudioPlayer` instance is used to play `AudioPlayerItem`. It's an easy to use AVPlayer with simple methods to
/// handle the whole playing audio process.
///
/// You can get events (such as state change or time observation) by registering a delegate.
@objcMembers public class AudioPlayer: NSObject {
    // MARK: Handlers

    /// The background handler.
    let backgroundHandler = BackgroundHandler()

    /// Reachability for network connection.
    let reachability = try! Reachability()

    // MARK: Event producers

    /// The network event producer.
    lazy var networkEventProducer: NetworkEventProducer = {
        NetworkEventProducer(reachability: self.reachability)
    }()

    /// The player event producer.
    let playerEventProducer = PlayerEventProducer()

    /// The seek event producer.
    let seekEventProducer = SeekEventProducer()

    /// The quality adjustment event producer.
    var qualityAdjustmentEventProducer = QualityAdjustmentEventProducer()

    /// The audio item event producer.
    var audioItemEventProducer = AudioItemEventProducer()

    /// The retry event producer.
    var retryEventProducer = RetryEventProducer()

    // MARK: Player

    /// The queue containing items to play.
    var queue: AudioItemQueue?

    /// Cached AVAssets, mainly used for preloading next item.
    var cachedAssets: [URL: AVURLAsset] = [:]

    /// The audio player.
    var player: AVPlayer? {
        didSet {
            player?.allowsExternalPlayback = allowExternalPlayback
            player?.volume = volume
            player?.rate = rate
            updatePlayerForBufferingStrategy()

            if let player = player {
                playerEventProducer.player = player
                audioItemEventProducer.item = currentItem
                playerEventProducer.startProducingEvents()
                audioItemEventProducer.startProducingEvents()
                qualityAdjustmentEventProducer.startProducingEvents()

                // Start producing network events, if not already doing so
                networkEventProducer.startProducingEvents()
                if #available(OSX 10.12.2, *) {
                    registerRemoteControlCommands()
                }
            } else {
                playerEventProducer.player = nil
                audioItemEventProducer.item = nil
                playerEventProducer.stopProducingEvents()
                audioItemEventProducer.stopProducingEvents()
                qualityAdjustmentEventProducer.stopProducingEvents()
            }
        }
    }

    /// The current item being played.
    public internal(set) var currentItem: AudioItem? {
        didSet {
            if let currentItem = currentItem {
                //Stops the current player
                player?.rate = 0
                player = nil

                //Ensures the audio session is active
                setAudioSession(active: true)

                //Reset special state flags
                pausedForInterruption = false
                stateBeforeBuffering = nil
                stateWhenConnectionLost = nil
                queuedSeek = nil

                //Sets new state
                let info = currentItem.url(for: currentQuality)
                if isOnline || info.url.ap_isOfflineURL {
                    state = .buffering
                } else {
                    stateWhenConnectionLost = .buffering
                    state = .waitingForConnection
                    return
                }

                //Reset special state flags
                pausedForInterruption = false

                //Create new AVPlayerItem
                let playerItem = getAVPlayerItem(forUrl: info.url)

                //Creates new player
                player = AVPlayer(playerItem: playerItem)

                currentQuality = info.quality

                //Updates information on the lock screen
                updateNowPlayingInfoCenter()

                //Calls delegate
                if oldValue != currentItem {
                    delegate?.audioPlayer?(self, willStartPlaying: currentItem)
                }
                player?.rate = rate
            } else if (player != nil) {
                stop()
            }
        }
    }

    /// The latest error on failed state
    public var failedError: Error?

    // MARK: Public properties

    /// The delegate that will be called upon events.
    public weak var delegate: AudioPlayerDelegate?

    /// Defines the maximum to wait after a connection loss before putting the player to Stopped mode and cancelling
    /// the resume. Default value is 60 seconds.
    public var maximumConnectionLossTime = TimeInterval(60)

    /// Defines whether the player should automatically adjust sound quality based on the number of interruption before
    /// a delay and the maximum number of interruption whithin this delay. Default value is `true`.
    public var adjustQualityAutomatically = true

    /// Defines the default quality used to play. Default value is `.medium`
    public var defaultQuality = AudioQuality.medium

    /// Defines the delay within which the player wait for an interruption before upgrading the quality. Default value
    /// is 10 minutes.
    public var adjustQualityTimeInternal: TimeInterval {
        get {
            return qualityAdjustmentEventProducer.adjustQualityTimeInternal
        }
        set {
            qualityAdjustmentEventProducer.adjustQualityTimeInternal = newValue
        }
    }

    /// Defines the maximum number of interruption to have within the `adjustQualityTimeInterval` delay before
    /// downgrading the quality. Default value is 5.
    public var adjustQualityAfterInterruptionCount: Int {
        get {
            return qualityAdjustmentEventProducer.adjustQualityAfterInterruptionCount
        }
        set {
            qualityAdjustmentEventProducer.adjustQualityAfterInterruptionCount = newValue
        }
    }

    /// The maximum number of interruption before putting the player to Stopped mode. Default value is 10.
    public var maximumRetryCount: Int {
        get {
            return retryEventProducer.maximumRetryCount
        }
        set {
            retryEventProducer.maximumRetryCount = newValue
        }
    }

    /// The delay to wait before cancelling last retry and retrying. Default value is 10 seconds.
    public var retryTimeout: TimeInterval {
        get {
            return retryEventProducer.retryTimeout
        }
        set {
            retryEventProducer.retryTimeout = newValue
        }
    }

    /// Defines whether external playback to AirPlay devices is enabled. Default value is `true`
    public var allowExternalPlayback = true

    /// Defines which audio session category to set. Default value is `AVAudioSession.Category.playback`.
    @objc(sessionCategory)
    public var objc_sessionCategory = AVAudioSession.Category.playback.rawValue {
        didSet {
            self.sessionCategory = AVAudioSession.Category.init(rawValue: objc_sessionCategory)
        }
    }
    /// Defines which audio session category to set. Default value is `AVAudioSession.Category.playback`.
    @nonobjc
    public var sessionCategory = AVAudioSession.Category.playback

    /// Defines which audio session mode to set. Default value is `AVAudioSession.Mode.default`.
    @objc(sessionMode)
    public var objc_sessionMode = AVAudioSession.Mode.default.rawValue {
        didSet {
            self.sessionMode = AVAudioSession.Mode.init(rawValue: objc_sessionMode)
        }
    }
    /// Defines which audio session mode to set. Default value is `AVAudioSession.Mode.default`.
    @nonobjc
    public var sessionMode = AVAudioSession.Mode.default

    /// Defines which time pitch algorithm to use. Default value is `AVAudioTimePitchAlgorithm.lowQualityZeroLatency`.
    @objc(timePitchAlgorithm)
    public var objc_timePitchAlgorithm = AVAudioTimePitchAlgorithm.lowQualityZeroLatency.rawValue {
        didSet {
            self.timePitchAlgorithm = AVAudioTimePitchAlgorithm.init(rawValue: objc_timePitchAlgorithm)
        }
    }
    /// Defines which time pitch algorithm to use. Default value is `AVAudioTimePitchAlgorithm.lowQualityZeroLatency`.
    @nonobjc
    public var timePitchAlgorithm = AVAudioTimePitchAlgorithm.lowQualityZeroLatency

    /// Defines whether the player should resume after a system interruption or not. Default value is `true`.
    public var resumeAfterInterruption = true

    /// Defines whether the player should resume after a connection loss or not. Default value is `true`.
    public var resumeAfterConnectionLoss = true

    /// Defines the mode of the player. Default is `.Normal`.
    public var mode = AudioPlayerMode.normal {
        didSet {
            queue?.mode = mode
        }
    }

    /// Defines the volume of the player. `1.0` means 100% and `0.0` is 0%.
    public var volume = Float(1) {
        didSet {
            player?.volume = volume
        }
    }

    /// Defines the rate of the player. Default value is 1.
    public var rate = Float(1) {
        didSet {
            if case .playing = state {
                player?.rate = rate
                updateNowPlayingInfoCenter()
            }
        }
    }

    /// Defines the buffering strategy used to determine how much to buffer before starting playback
    public var bufferingStrategy: AudioPlayerBufferingStrategy = .defaultBuffering {
        didSet {
            updatePlayerForBufferingStrategy()
        }
    }

    /// Defines the preferred buffer duration in seconds before playback begins. Defaults to 60.
    /// Works on iOS/tvOS 10+ when `bufferingStrategy` is `.playWhenPreferredBufferDurationFull`.
    public var preferredBufferDurationBeforePlayback = TimeInterval(60)

    /// Defines the preferred size of the forward buffer for the underlying `AVPlayerItem`.
    /// Works on iOS/tvOS 10+, default is 0, which lets `AVPlayer` decide.
    public var preferredForwardBufferDuration = TimeInterval(0)

    @objc(remoteCommandsEnabled)
    public var objc_remoteCommandsEnabled: [Int] = [AudioPlayerRemoteCommand.changePlaybackPosition.rawValue,
                                                    AudioPlayerRemoteCommand.previousTrack.rawValue,
                                                    AudioPlayerRemoteCommand.playPause.rawValue,
                                                    AudioPlayerRemoteCommand.nextTrack.rawValue] {
        didSet {
            remoteCommandsEnabled = objc_remoteCommandsEnabled.map({ AudioPlayerRemoteCommand(rawValue: $0)! })
        }
    }

    /// Defines which remote control commands should be enabled. Max shown on iOS is 3 commands.
    public var remoteCommandsEnabled: [AudioPlayerRemoteCommand] = [.changePlaybackPosition, .previousTrack, .playPause, .nextTrack] {
        didSet {
            if #available(OSX 10.12.2, *) {
                unregisterRemoteControlCommands(oldValue)
                registerRemoteControlCommands()
            }
        }
    }

    /// Defines how to behave when the user is seeking through the lockscreen or the control center.
    ///
    /// - multiplyRate: Multiples the rate by a factor.
    /// - changeTime:   Changes the current position by adding/substracting a time interval.
    public enum SeekingBehavior {
        case multiplyRate(Float)
        case changeTime(every: TimeInterval, delta: TimeInterval)

        func handleSeekingStart(player: AudioPlayer, forward: Bool) {
            switch self {
            case .multiplyRate(let rateMultiplier):
                if forward {
                    player.rate = player.rate * rateMultiplier
                } else {
                    player.rate = -(player.rate * rateMultiplier)
                }

            case .changeTime:
                player.seekEventProducer.isBackward = !forward
                player.seekEventProducer.startProducingEvents()
            }
        }

        func handleSeekingEnd(player: AudioPlayer, forward: Bool) {
            switch self {
            case .multiplyRate(let rateMultiplier):
                if forward {
                    player.rate = player.rate / rateMultiplier
                } else {
                    player.rate = -(player.rate / rateMultiplier)
                }

            case .changeTime:
                player.seekEventProducer.stopProducingEvents()
            }
        }
    }

    /// Defines the rate behavior of the player when the backward/forward buttons are pressed. Default value
    /// is `multiplyRate(2)`.
    public var seekingBehavior = SeekingBehavior.multiplyRate(2) {
        didSet {
            if case .changeTime(let timerInterval, _) = seekingBehavior {
                seekEventProducer.intervalBetweenEvents = timerInterval
            }
        }
    }

    // MARK: Readonly properties

    /// The current state of the player.
    public internal(set) var state = AudioPlayerState.stopped {
        didSet {
            updateNowPlayingInfoCenter()

            if state != oldValue {
                if [.buffering, .waitingForConnection].contains(oldValue) {
                    backgroundHandler.endBackgroundTask()
                }
                if [.buffering, .waitingForConnection].contains(state) {
                    backgroundHandler.beginBackgroundTask()
                }
                delegate?.audioPlayer?(self, didChangeStateFrom: oldValue, to: state)
            }
        }
    }

    /// The current quality being played.
    public internal(set) var currentQuality: AudioQuality

    // MARK: Private properties

    /// A SeekOperation which will be executed once currentItem is ready to play.
    var queuedSeek: SeekOperation?

    /// A boolean value indicating whether the player has been paused because of a system interruption.
    var pausedForInterruption = false

    /// A boolean value indicating if quality is being changed. It's necessary for the interruption count to not be
    /// incremented while new quality is buffering.
    var qualityIsBeingChanged = false

    /// The state before the player went into .Buffering. It helps to know whether to restart or not the player.
    var stateBeforeBuffering: AudioPlayerState?

    /// The state of the player when the connection was lost
    var stateWhenConnectionLost: AudioPlayerState?

    /// Convenience for checking whether currentItem being played is an offline resource.
    var currentItemIsOffline: Bool {
        get {
            return currentItem?.soundURLs[currentQuality]?.ap_isOfflineURL ?? false
        }
    }

    /// Convenience for checking if platform is currently online
    var isOnline: Bool {
        get {
            return reachability.connection != Reachability.Connection.unavailable
        }
    }

    // MARK: Initialization

    /// Initializes a new AudioPlayer.
    public override init() {
        currentQuality = defaultQuality
        super.init()

        playerEventProducer.eventListener = self
        networkEventProducer.eventListener = self
        audioItemEventProducer.eventListener = self
        qualityAdjustmentEventProducer.eventListener = self
    }

    /// Deinitializes the AudioPlayer. On deinit, the player will simply stop playing anything it was previously
    /// playing.
    deinit {
        networkEventProducer.stopProducingEvents()
        stop()
    }

    // MARK: Utility methods

    /// Updates the MPNowPlayingInfoCenter with current item's info.
    func updateNowPlayingInfoCenter() {
        #if os(iOS) || os(tvOS)
            KDEDebug("updateNowPlayingInfoCenter")
            if let item = currentItem {
                setRemoteControlCommandsEnabled(true)
                MPNowPlayingInfoCenter.default().ap_update(
                    with: item,
                    duration: currentItemDuration,
                    progression: currentItemProgression,
                    playbackRate: player?.rate ?? 0)
            } else {
                setRemoteControlCommandsEnabled(false)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        #endif
    }

    /// Enables or disables the `AVAudioSession` and sets the right category.
    ///
    /// - Parameter active: A boolean value indicating whether the audio session should be set to active or not.
    func setAudioSession(active: Bool) {
        #if os(iOS) || os(tvOS)
            do {
                if (active) {
                    try AVAudioSession.sharedInstance().setCategory(sessionCategory, mode: sessionMode)
                }
                try AVAudioSession.sharedInstance().setActive(active)
                KDEDebug("AVAudioSession setActive(\(active))")
            } catch {
                KDEDebug("AVAudioSession setActive(\(active)) Error: \(error.localizedDescription)")
            }
        #endif
    }

    // MARK: Public computed properties

    /// Boolean value indicating whether the player should resume playing (after buffering)
    var shouldResumePlaying: Bool {
        return !state.isPaused &&
            (stateWhenConnectionLost.map { !$0.isPaused } ?? true) &&
            (stateBeforeBuffering.map { !$0.isPaused } ?? true)
    }

    // MARK: Retrying

    /// This will retry to play current item and seek back at the correct position if possible (or enabled). If not,
    /// it'll just play the next item in queue.
    func retryOrPlayNext() {
        guard !state.isPlaying else {
            retryEventProducer.stopProducingEvents()
            return
        }

        let cip = currentItemProgression
        let ci = currentItem
        currentItem = ci
        if let cip = cip {
            //We can't call self.seek(to:) in here since the player is new
            //and `cip` is probably not in the seekableTimeRanges.
            player?.seek(to: CMTime(timeInterval: cip))
        }
    }

    /// Updates the current player based on the current buffering strategy.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerForBufferingStrategy() {
        player?.automaticallyWaitsToMinimizeStalling = self.bufferingStrategy != .playWhenBufferNotEmpty
    }

    /// Updates a given player item based on the `preferredForwardBufferDuration` set.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerItemForBufferingStrategy(_ playerItem: AVPlayerItem) {
        //Nothing strategy-specific yet
        playerItem.preferredForwardBufferDuration = self.preferredForwardBufferDuration
    }
}

extension AudioPlayer: EventListener {
    /// The implementation of `EventListener`. It handles network events, player events, audio item events, quality
    /// adjustment events, retry events and seek events.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - eventProducer: The producer of the event.
    func onEvent(_ event: Event, generetedBy eventProducer: EventProducer) {
        if let event = event as? NetworkEventProducer.NetworkEvent {
            handleNetworkEvent(from: eventProducer, with: event)
        } else if let event = event as? PlayerEventProducer.PlayerEvent {
            handlePlayerEvent(from: eventProducer, with: event)
        } else if let event = event as? AudioItemEventProducer.AudioItemEvent {
            handleAudioItemEvent(from: eventProducer, with: event)
        } else if let event = event as? QualityAdjustmentEventProducer.QualityAdjustmentEvent {
            handleQualityEvent(from: eventProducer, with: event)
        } else if let event = event as? RetryEventProducer.RetryEvent {
            handleRetryEvent(from: eventProducer, with: event)
        } else if let event = event as? SeekEventProducer.SeekEvent {
            handleSeekEvent(from: eventProducer, with: event)
        }
    }
}
