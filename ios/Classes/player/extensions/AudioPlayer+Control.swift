//
//  AudioPlayer+Control.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 29/03/16.
//  Copyright © 2016 Kevin Delannoy. All rights reserved.
//

import CoreMedia
#if os(iOS) || os(tvOS)
    import UIKit
#endif

extension AudioPlayer {
    /// Resumes the player.
    public func resume() {
        //Ensure pause flag is no longer set
        pausedForInterruption = false

        //Pause initiates a background task, end it on resume
        backgroundHandler.endBackgroundTask()

        //Ensures the audio session is active
        setAudioSession(active: true)

        player?.rate = rate

        //We don't wan't to change the state to Playing in case it's Buffering. That
        //would be a lie.
        //If streaming go to buffering state, allowing non-default buffering strategies to work
        if !state.isPlaying && !state.isBuffering {
            state = currentItemIsOffline ? .playing : .buffering
        }

        retryEventProducer.startProducingEvents()
    }

    /// Pauses the player.
    public func pause() {
        //We ensure the player actually pauses
        player?.rate = 0
        state = .paused

        retryEventProducer.stopProducingEvents()

        //Let's begin a background task for the player to keep buffering if the app is in
        //background. This will mimic the default behavior of `AVPlayer` when pausing while the
        //app is in foreground.
        backgroundHandler.beginBackgroundTask()
    }

    /// Starts playing the current item immediately. Works on iOS/tvOS 10+ and macOS 10.12+
    func playImmediately() {
        //NOTE: No need to do anything if we're already playing
        guard let player = player, player.timeControlStatus != .playing else {
            return
        }
        self.state = .playing
        player.playImmediately(atRate: rate)

        retryEventProducer.stopProducingEvents()
    }

    /// Plays previous item in the queue or rewind current item.
    public func previous() {
        if let previousItem = queue?.previousItem() {
            currentItem = previousItem
        } else {
            seek(to: 0)
        }
    }

    /// Plays next item in the queue.
    public func next() {
        if let nextItem = queue?.nextItem() {
            currentItem = nextItem
        }
    }

    /// Plays the next item in the queue and if there isn't, the player will stop.
    public func nextOrStop() {
        if let nextItem = queue?.nextItem() {
            currentItem = nextItem
        } else {
            stop()
        }
    }

    /// Stops the player and clear the queue.
    public func stop() {
        if (state == .stopped) {
            return
        }
        retryEventProducer.stopProducingEvents()

        if let _ = player {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }

        if let _ = currentItem {
            currentItem = nil
        }
        if let _ = queue {
            queue = nil
        }

        state = .stopped

        // Fix: Some AVURLAssets may take a short while to seize I/O ops.
        // We therefore delay ending the AudioSession
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: { [weak self] in
            guard let self = self else { return }
            self.setAudioSession(active: false)
        })
    }

    /// Seeks to a specific time.
    ///
    /// - Parameters:
    ///   - time: The time to seek to.
    ///   - byAdaptingTimeToFitSeekableRanges: A boolean value indicating whether the time should be adapted to current
    ///         seekable ranges in order to be bufferless.
    ///   - toleranceBefore: The tolerance allowed before time.
    ///   - toleranceAfter: The tolerance allowed after time.
    ///   - completionHandler: The optional callback that gets executed upon completion with a boolean param indicating
    ///         if the operation has finished.
    public func seek(to time: TimeInterval,
                     byAdaptingTimeToFitSeekableRanges: Bool = false,
                     toleranceBefore: CMTime = CMTime.positiveInfinity,
                     toleranceAfter: CMTime = CMTime.positiveInfinity,
                     completionHandler: ((Bool) -> Void)? = nil) {
        KDEDebug("seek to \(time)")
        guard let earliest = currentItemSeekableRange?.earliest,
            let latest = currentItemSeekableRange?.latest else {
                //In case we don't have a valid `seekableRange`, although this *shouldn't* happen
                //let's just call `AVPlayer.seek(to:)` with given values.
                seekSafely(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter,
                           completionHandler: completionHandler)
                return
        }

        if !byAdaptingTimeToFitSeekableRanges || (time >= earliest && time <= latest) {
            //Time is in seekable range, there's no problem here.
            seekSafely(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter,
                 completionHandler: completionHandler)
        } else if time < earliest {
            //Time is before seekable start, so just move to the most early position as possible.
            seekToSeekableRangeStart(padding: 1, completionHandler: completionHandler)
        } else if time > latest {
            //Time is larger than possibly, so just move forward as far as possible.
            seekToSeekableRangeEnd(padding: 1, completionHandler: completionHandler)
        }
    }

    /// Seeks backwards as far as possible.
    ///
    /// - Parameter padding: The padding to apply if any.
    /// - completionHandler: The optional callback that gets executed upon completion with a boolean param indicating
    ///     if the operation has finished.
    public func seekToSeekableRangeStart(padding: TimeInterval, completionHandler: ((Bool) -> Void)? = nil) {
        guard let range = currentItemSeekableRange else {
                completionHandler?(false)
                return
        }
        let position = min(range.latest, range.earliest + padding)
        seekSafely(to: position, completionHandler: completionHandler)
    }

    /// Seeks forward as far as possible.
    ///
    /// - Parameter padding: The padding to apply if any.
    /// - completionHandler: The optional callback that gets executed upon completion with a boolean param indicating
    ///     if the operation has finished.
    public func seekToSeekableRangeEnd(padding: TimeInterval, completionHandler: ((Bool) -> Void)? = nil) {
        guard let range = currentItemSeekableRange else {
                completionHandler?(false)
                return
        }
        let position = max(range.earliest, range.latest - padding)
        seekSafely(to: position, completionHandler: completionHandler)
    }

    public func seekToRelativeTime(_ relativeTime: TimeInterval, completionHandler: ((Bool) -> Void)? = nil) {
        guard let currentTime = player?.currentTime(),
            currentTime.seconds.isFinite else {
                completionHandler?(false)
                return
        }
        let seekToAbsoluteTime = max(currentTime.seconds + relativeTime, 0)
        seek(to: seekToAbsoluteTime, byAdaptingTimeToFitSeekableRanges: false, toleranceBefore: CMTime.positiveInfinity, toleranceAfter: CMTime.positiveInfinity, completionHandler: completionHandler)
    }
}

extension AudioPlayer {

    fileprivate func seekSafely(to time: TimeInterval,
              toleranceBefore: CMTime = CMTime.positiveInfinity,
              toleranceAfter: CMTime = CMTime.positiveInfinity,
              completionHandler: ((Bool) -> Void)?) {
        if (player?.currentItem?.status == .readyToPlay) {
            KDEDebug("seekSafely: seek to \(time)")
            player?.seek(to: CMTime(timeInterval: time), toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { [weak self] finished in
                completionHandler?(finished)
                self?.updateNowPlayingInfoCenter()
            }
        } else if (player?.currentItem?.status == .unknown) {
            KDEDebug("seekSafely: currentItem not loaded yet, queue the seek for when it's ready")
            // status is unknown, queue the seek for when status changes to ready
            queuedSeek = SeekOperation(time: time,
                                       toleranceBefore: toleranceBefore,
                                       toleranceAfter: toleranceAfter,
                                       completionHandler: completionHandler)
        } else {
            KDEDebug("seekSafely: currentItem is failed, cannot seek")
            // seek is not possible
            completionHandler?(false)
        }
    }
}
