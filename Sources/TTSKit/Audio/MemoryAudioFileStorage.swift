import AudioToolbox
import Foundation

final class MemoryAudioFileStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func read(position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer) -> UInt32 {
    lock.lock()
    defer { lock.unlock() }
    guard position >= 0, position < Int64(data.count) else { return 0 }
    let start = Int(position)
    let byteCount = min(Int(count), data.count - start)
    data.copyBytes(
      to: buffer.assumingMemoryBound(to: UInt8.self), from: start..<(start + byteCount))
    return UInt32(byteCount)
  }

  func write(position: Int64, count: UInt32, from buffer: UnsafeRawPointer) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard position >= 0, position <= Int64(Int.max) - Int64(count) else { return false }
    let start = Int(position)
    let end = start + Int(count)
    if data.count < end { data.count = end }
    data.replaceSubrange(
      start..<end,
      with: UnsafeRawBufferPointer(start: buffer, count: Int(count)))
    return true
  }

  func size() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return Int64(data.count)
  }

  func setSize(_ size: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard size >= 0, size <= Int64(Int.max) else { return false }
    data.count = Int(size)
    return true
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

nonisolated(unsafe) let memoryAudioFileRead: AudioFile_ReadProc = {
  clientData, position, count, buffer, actualCount in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  actualCount.pointee = storage.read(position: position, count: count, into: buffer)
  return noErr
}

nonisolated(unsafe) let memoryAudioFileWrite: AudioFile_WriteProc = {
  clientData, position, count, buffer, actualCount in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  guard storage.write(position: position, count: count, from: buffer) else {
    actualCount.pointee = 0
    return kAudioFilePositionError
  }
  actualCount.pointee = count
  return noErr
}

nonisolated(unsafe) let memoryAudioFileGetSize: AudioFile_GetSizeProc = { clientData in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  return storage.size()
}

nonisolated(unsafe) let memoryAudioFileSetSize: AudioFile_SetSizeProc = {
  clientData, size in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  return storage.setSize(size) ? noErr : kAudioFilePositionError
}

extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
