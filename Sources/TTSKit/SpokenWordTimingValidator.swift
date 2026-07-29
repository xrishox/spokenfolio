import Foundation

package enum SpokenWordTimingValidationError: Error, LocalizedError, Equatable {
  case tooMany(Int)
  case invalidRange(index: Int)
  case invalidTimestamp(index: Int)
  case nonmonotonic(index: Int)

  package var errorDescription: String? {
    switch self {
    case .tooMany(let count):
      "The speech engine returned too many timing entries (\(count))."
    case .invalidRange(let index):
      "The speech engine returned an invalid timing text range at entry \(index)."
    case .invalidTimestamp(let index):
      "The speech engine returned an invalid timing timestamp at entry \(index)."
    case .nonmonotonic(let index):
      "The speech engine returned nonmonotonic timing at entry \(index)."
    }
  }
}

/// Validates private-engine timing payloads before they cross a worker
/// boundary. Ranges are UTF-16 offsets into the exact request text and times
/// are relative to the first decoded PCM frame.
package enum SpokenWordTimingValidator {
  package static func validate(
    _ timings: [SpokenWordTiming], text: String, audioDuration: Double
  ) throws -> [SpokenWordTiming] {
    let utf16Count = text.utf16.count
    let maximumCount = min(16_384, max(32, utf16Count * 2))
    guard timings.count <= maximumCount else {
      throw SpokenWordTimingValidationError.tooMany(timings.count)
    }
    guard audioDuration.isFinite, audioDuration > 0 else {
      throw SpokenWordTimingValidationError.invalidTimestamp(index: 0)
    }

    var result: [SpokenWordTiming] = []
    result.reserveCapacity(timings.count)
    for (index, timing) in timings.enumerated() {
      guard timing.utf16Offset >= 0, timing.utf16Length > 0,
        timing.utf16Offset < utf16Count,
        timing.utf16Length <= utf16Count - timing.utf16Offset
      else { throw SpokenWordTimingValidationError.invalidRange(index: index) }
      guard timing.startSeconds.isFinite, timing.startSeconds >= 0,
        timing.startSeconds <= audioDuration + 0.100
      else { throw SpokenWordTimingValidationError.invalidTimestamp(index: index) }
      if let previous = result.last {
        if timing == previous { continue }
        guard timing.utf16Offset > previous.utf16Offset,
          timing.startSeconds >= previous.startSeconds
        else { throw SpokenWordTimingValidationError.nonmonotonic(index: index) }
      }
      result.append(timing)
    }
    return result
  }
}
