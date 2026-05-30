import Cocoa
import CoreGraphics
import Foundation

/// Manages gesture recognition from touch input
class GestureRecognizer {

    // MARK: - Properties

    /// Configuration for gesture detection
    var configuration = GestureConfiguration()

    /// Current gesture state
    private(set) var state: GestureState = .idle

    /// Delegate for gesture events
    weak var delegate: GestureRecognizerDelegate?

    // Position tracking
    private var lastFingerPositions: [MTPoint] = []
    private var gestureStartTime: Double = 0
    private var gestureStartPosition: MTPoint?
    private var lastCentroid: MTPoint?
    private var frameCount: Int = 0

    // Stability tracking - prevents false gesture ends during brief state transitions
    private var stableFrameCount: Int = 0
    private var validGestureFrameCount: Int = 0
    private var pendingGestureEndTime: Double?

    // Cooldown after 4-finger cancellation
    // Prevents accidental gesture triggers when lifting one finger during Mission Control
    private var isInCancellationCooldown: Bool = false

    // MARK: - Public Interface

    /// Process new touch data from the multitouch device
    /// - Parameters:
    ///   - touches: Raw pointer to touch data array
    ///   - count: Number of touches in the array
    ///   - timestamp: Timestamp of the touch frame
    ///   - modifierFlags: Current modifier key flags (captured on main thread by caller)
    func processTouches(
        _ touches: UnsafeMutableRawPointer, count: Int, timestamp: Double,
        modifierFlags: CGEventFlags
    ) {
        // Check modifier key requirement first (if enabled)
        if configuration.requireModifierKey {
            let requiredFlagPresent: Bool
            switch configuration.modifierKeyType {
            case .shift:
                requiredFlagPresent = modifierFlags.contains(.maskShift)
            case .control:
                requiredFlagPresent = modifierFlags.contains(.maskControl)
            case .option:
                requiredFlagPresent = modifierFlags.contains(.maskAlternate)
            case .command:
                requiredFlagPresent = modifierFlags.contains(.maskCommand)
            }

            if !requiredFlagPresent {
                // Required modifier not held - cancel any active gesture and return
                if state != .idle {
                    handleGestureCancel()
                }
                return
            }
        }

        let activeFingerCount = unsafe Self.activeFingerCount(from: touches, count: count)
        // Palm filters classify contacts at gesture start, then freeze: once a drag
        // is underway we stop rejecting contacts so a finger drifting into an edge
        // band (or a hard press spiking its size) can never drop out mid-drag. The
        // raw-contact 4-finger cancel below still guards against added palms.
        let validFingers = unsafe Self.validFingerPositions(
            from: touches, count: count, configuration: configuration,
            applyPalmRejection: state != .dragging)

        let fingerCount = validFingers.count

        // ALWAYS cancel on 4+ raw active contacts regardless of configuration.
        // This ensures Mission Control and other system gestures always work
        // and prevents filtered/palm contacts from turning a 4+ contact frame into
        // an accidental three-finger middle click.
        if activeFingerCount >= 4 {
            if state != .idle {
                handleGestureCancel()
            }
            // Enter cooldown to prevent restart when finger is briefly lifted
            isInCancellationCooldown = true
            return
        }

        // Clear cooldown only after fingers drop below the three-finger gesture shape.
        // Do not clear merely because a 4+ system gesture briefly becomes 3 fingers
        // during lift-off; that path can create accidental middle clicks.
        if activeFingerCount <= 2 {
            isInCancellationCooldown = false
        }

        // Process gesture based on finger count
        // - 4+ fingers: cancelled above
        // - 3 fingers: always valid for starting/continuing gesture
        // - 2 fingers: valid for continuing drag if allowReliftDuringDrag is enabled
        // - 0-1 fingers: ends the gesture
        let canReliftDuringDrag =
            configuration.allowReliftDuringDrag
            && state == .dragging
            && fingerCount >= 2
        let isValidGesture =
            !isInCancellationCooldown
            && (fingerCount == 3 || canReliftDuringDrag)

        if isValidGesture {
            handleValidGesture(fingers: validFingers, timestamp: timestamp)
        } else if state != .idle {
            // Gesture no longer valid for current finger count
            // (needs 3 to start, or 2+ if allowReliftDuringDrag is on during drag)
            // Use stable frame count to prevent false ends during brief transitions
            if stableFrameCount == 0 {
                pendingGestureEndTime = timestamp
            }
            stableFrameCount += 1
            if stableFrameCount >= 2 {
                handleGestureEnd(timestamp: pendingGestureEndTime ?? timestamp)
            }
        } else {
            validGestureFrameCount = 0
        }

        frameCount += 1
    }

    /// Returns the positions of contacts that count as fingers for gesture detection.
    /// - Parameter applyPalmRejection: when `false` (e.g. during an active drag) the
    ///   palm filters are skipped and every touching contact is returned, so a
    ///   recognized gesture is never broken by a contact entering an edge band or
    ///   growing in size. Pass `true` when deciding whether to *start* a gesture.
    static func validFingerPositions(
        from touches: UnsafeMutableRawPointer,
        count: Int,
        configuration: GestureConfiguration,
        applyPalmRejection: Bool = true
    ) -> [MTPoint] {
        let touchArray = unsafe touches.bindMemory(to: MTTouch.self, capacity: count)
        var validFingers: [MTPoint] = []
        validFingers.reserveCapacity(count)

        for i in 0..<count {
            let touch = unsafe touchArray[i]
            if touch.state == 3 || touch.state == 4 {
                let position = touch.normalizedVector.position

                if applyPalmRejection && Self.isPalmContact(touch, configuration: configuration) {
                    continue
                }

                validFingers.append(position)
            }
        }

        return validFingers
    }

    /// Per-contact palm classification. Combines edge-zone rejection (position-based,
    /// scale-independent) with the absolute contact-size backstop. Coordinates are
    /// normalized 0-1 with the origin at the lower-left: y=0 bottom, x=0 left.
    private static func isPalmContact(
        _ touch: MTTouch, configuration: GestureConfiguration
    ) -> Bool {
        // Edge exclusion zone — a resting palm / heel / thumb base typically makes
        // contact near the bottom or side edges. The top edge is deliberately never
        // excluded: it is where fingers legitimately reach during a gesture.
        if configuration.exclusionZoneEnabled {
            let band = configuration.exclusionZoneSize
            let position = touch.normalizedVector.position
            if configuration.excludeBottomEdge && position.y < band { return true }
            if configuration.excludeLeftEdge && position.x < band { return true }
            if configuration.excludeRightEdge && position.x > 1 - band { return true }
        }

        // Absolute contact-size backstop. Note: zTotal's absolute scale is
        // hardware-dependent, so this is a coarse safety net rather than the
        // primary discriminator (which is the edge zone above).
        if configuration.contactSizeFilterEnabled && touch.zTotal > configuration.maxContactSize {
            return true
        }

        return false
    }

    private static func activeFingerCount(from touches: UnsafeMutableRawPointer, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let touchArray = unsafe touches.bindMemory(to: MTTouch.self, capacity: count)
        var activeCount = 0

        for i in 0..<count {
            let touch = unsafe touchArray[i]
            if touch.state == 3 || touch.state == 4 {
                activeCount += 1
            }
        }

        return activeCount
    }

    /// Reset gesture recognition state
    func reset() {
        state = .idle
        lastFingerPositions = []
        gestureStartPosition = nil
        lastCentroid = nil
        gestureStartTime = 0
        frameCount = 0
        stableFrameCount = 0
        validGestureFrameCount = 0
        pendingGestureEndTime = nil
        isInCancellationCooldown = false  // Clear cooldown on reset
    }

    // MARK: - Private Methods

    private func handleValidGesture(fingers: [MTPoint], timestamp: Double) {
        stableFrameCount = 0
        pendingGestureEndTime = nil
        validGestureFrameCount += 1

        let centroid = calculateCentroid(fingers: fingers)

        // Filter large centroid jumps from finger add/remove (not fast movement)
        if let last = lastCentroid {
            let jump = centroid.distance(to: last)
            if jump > 0.15 {
                lastCentroid = centroid
                lastFingerPositions = fingers
                return
            }
        }

        switch state {
        case .idle:
            // Start new gesture
            state = .possibleTap
            gestureStartTime = timestamp
            gestureStartPosition = centroid
            lastCentroid = centroid
            lastFingerPositions = fingers
            delegate?.gestureRecognizerDidStart(self, at: centroid)

        case .possibleTap:
            // Check if we should transition to drag
            guard let startPos = gestureStartPosition else { return }
            let deltaX = centroid.x - startPos.x
            let deltaY = centroid.y - startPos.y
            let movement = startPos.distance(to: centroid)

            if configuration.passThroughVerticalSwipes {
                let horizontalMovement = abs(deltaX)
                let verticalMovement = abs(deltaY)
                let isClearlyVertical =
                    verticalMovement >= configuration.verticalSwipeThreshold
                    && verticalMovement >= horizontalMovement * configuration.verticalSwipeDominanceRatio

                if isClearlyVertical {
                    handleGestureCancel()
                    return
                }

                let isPotentialVerticalSwipe =
                    verticalMovement > horizontalMovement * configuration.verticalSwipeDominanceRatio

                if isPotentialVerticalSwipe {
                    lastCentroid = centroid
                    return
                }
            }

            // Only transition to drag if there is actual movement
            // Resting fingers (no movement) should NOT trigger a drag
            if movement > configuration.moveThreshold {
                state = .dragging
                lastCentroid = centroid
                delegate?.gestureRecognizerDidBeginDragging(self)
            } else {
                lastCentroid = centroid
            }

        case .dragging:
            if let last = lastCentroid {
                let deltaX = centroid.x - last.x
                let deltaY = centroid.y - last.y

                // Filter jumps from finger changes
                let maxDelta: Float = 0.15
                if abs(deltaX) < maxDelta && abs(deltaY) < maxDelta {
                    if abs(deltaX) > 0.0001 || abs(deltaY) > 0.0001 {
                        let gestureData = GestureData(
                            centroid: centroid,
                            velocity: MTPoint(x: 0, y: 0),
                            pressure: 0,
                            fingerCount: fingers.count,
                            startPosition: gestureStartPosition,
                            lastPosition: last
                        )
                        delegate?.gestureRecognizerDidUpdateDragging(self, with: gestureData)
                    }
                }
            }
            lastCentroid = centroid

        case .waitingForRelease:
            break
        }

        lastFingerPositions = fingers
    }

    private func handleGestureEnd(timestamp: Double) {
        let elapsed = timestamp - gestureStartTime

        switch state {
        case .possibleTap:
            // Only trigger tap if:
            // 1. At least two valid touch frames were observed (filters one-frame noise)
            // 2. Duration is long enough to be intentional but less than tap threshold
            // 3. Duration doesn't exceed max hold duration (safety check for edge cases)
            if validGestureFrameCount >= configuration.minimumTapFrameCount
                && elapsed >= configuration.minimumTapDuration
                && elapsed < configuration.tapThreshold
                && elapsed <= configuration.maxTapHoldDuration {
                delegate?.gestureRecognizerDidTap(self)
            } else {
                // Gesture ended without a tap - notify delegate to reset state
                delegate?.gestureRecognizerDidCancel(self)
            }
        case .dragging:
            delegate?.gestureRecognizerDidEndDragging(self)
        default:
            break
        }

        reset()
    }

    /// Cancel gesture without completing it (e.g., when 4th finger detected)
    private func handleGestureCancel() {
        switch state {
        case .possibleTap:
            // Cancel the possible tap - notify delegate so it can reset state
            delegate?.gestureRecognizerDidCancel(self)
        case .dragging:
            // Cancel the drag - don't complete it normally
            delegate?.gestureRecognizerDidCancelDragging(self)
        default:
            break
        }

        reset()
    }

    private func calculateCentroid(fingers: [MTPoint]) -> MTPoint {
        let sumX = fingers.reduce(0) { $0 + $1.x }
        let sumY = fingers.reduce(0) { $0 + $1.y }
        return MTPoint(x: sumX / Float(fingers.count), y: sumY / Float(fingers.count))
    }
}

// MARK: - Gesture Data

/// Data representing the current state of a gesture
struct GestureData: Sendable {
    let centroid: MTPoint
    let velocity: MTPoint
    let pressure: Float
    let fingerCount: Int
    let startPosition: MTPoint?
    let lastPosition: MTPoint

    /// Calculate frame-to-frame delta with sensitivity applied
    func frameDelta(from configuration: GestureConfiguration) -> (x: CGFloat, y: CGFloat) {
        let deltaX = CGFloat(centroid.x - lastPosition.x)
        let deltaY = CGFloat(centroid.y - lastPosition.y)

        // Filter jumps from finger changes
        if abs(deltaX) > 0.15 || abs(deltaY) > 0.15 {
            return (0, 0)
        }

        let sensitivity = CGFloat(configuration.effectiveSensitivity(for: velocity))
        return (deltaX * sensitivity, deltaY * sensitivity)
    }
}

// MARK: - Delegate Protocol

/// Protocol for receiving gesture recognition events
protocol GestureRecognizerDelegate: AnyObject {
    /// Called when a gesture starts (3 fingers detected)
    func gestureRecognizerDidStart(_ recognizer: GestureRecognizer, at position: MTPoint)

    /// Called when a tap gesture is recognized (quick tap)
    func gestureRecognizerDidTap(_ recognizer: GestureRecognizer)

    /// Called when dragging begins
    func gestureRecognizerDidBeginDragging(_ recognizer: GestureRecognizer)

    /// Called during drag with movement data
    func gestureRecognizerDidUpdateDragging(_ recognizer: GestureRecognizer, with data: GestureData)

    /// Called when dragging ends normally (user lifted fingers)
    func gestureRecognizerDidEndDragging(_ recognizer: GestureRecognizer)

    /// Called when gesture is cancelled from early state (e.g., possibleTap when 4th finger added)
    func gestureRecognizerDidCancel(_ recognizer: GestureRecognizer)

    /// Called when dragging is cancelled (e.g., 4th finger added for Mission Control)
    func gestureRecognizerDidCancelDragging(_ recognizer: GestureRecognizer)
}
