# UnsafeRawBufferPointer

* Proposal: [SE-0138](0138-unsaferawbufferpointer.md)
* Author: [Andrew Trick](https://github.com/atrick)
* Review manager: [Dave Abrahams](https://github.com/dabrahams)
* Status: **Implemented (Swift 3.0.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160919/027167.html)

Contents:
- [Introduction](#introduction)
- [Motivation](#motivation)
- [Proposed Solution](#proposed-solution)
- [Migration Examples](#migration-examples)
- [Detailed design](#detailed-design)
- [Implementation status](#implementation-status)
- [Impact on existing code](#impact-on-existing-code)
- [Alternatives considered](#alternatives-considered)

## Introduction

This is a purely additive proposal to improve the Swift 3 migration
experience.

[SE-0107: UnsafeRawPointer](0107-unsaferawpointer.md)
formalized Swift's memory model with respect to strict aliasing and
prevented arbitrary conversion between `UnsafePointer` types. When
moving to Swift 3, users will need to migrate much of their code
dealing with `UnsafePointer`s. The new `UnsafeRawPointer` makes that
possible. It provides a legal means to operate on raw memory
(independent of the type of values in memory), and it provides an API
for binding memory to a type for subsequent normal typed
access. However, migration is not always straightforward because
SE-0107 provided only minimal support for raw pointers. Extending raw
pointer support to the `UnsafeBufferPointer` type will fill in this
funcionality gap. This is especially important for code that currently
views "raw" bytes of memory as
`UnsafeBufferPointer<UInt8>`. Converting between `UInt8` and the
client's element type at every API transition is difficult to do
safely with the `bindMemory` API, but that can be avoided entirely by
changing the type the represents a view into raw bytes to
`UnsafeRawBufferPointer`.  For more background, see the
[UnsafeRawPointer Migration Guide](https://swift.org/migration-guide/se-0107-migrate.html).

Swift-evolution threads:
- [Week #1](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160808/thread.html#26173)
- [Week #2](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160815/thread.html#26254)
- [Week #3](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160822/thread.html#26553)
- [Week #4 (1)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160829/thread.html#26812)
- [Week #4 (2)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160829/thread.html#26844)
- [Week #5](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160905/thread.html#26947)

## Motivation

This proposal adds basic usability for working with raw memory without
breaking source. The need to provide higher level API for working with
raw memory buffers has always been evident, but making improvements in
this area depended on first introducing `UnsafeRawPointer`. It was not
clear until the final week of source-breaking changes whether SE-0107
would make it into Swift 3. Now that it has, we should do everything
possible in the remaining time to improve the migration experience and
encourage correct use of the memory model by introducing this low-risk
additive API.

Almost all API's that use raw pointers need to pass or return a length
associated with the raw memory "buffer". It is obvious that providing
a type that encapsulates a raw pointer with length would improve the
safety and readability of all of these interfaces. It would also support
automatic debug-mode bounds checking on each side of the interface.

In the short time that users have been migrating code, I have already
seen several cases that view raw memory as a collection of `UInt8` values. It
is natural for the same type that encapsulates a raw pointer and
length to also allow clients to view that memory as raw bytes without the
need to explicitly bind the memory type each time memory is
accessed. This would also improve performance in some cases that I've
encoutered by avoiding array copies. Let's call this new type
`Unsafe[Mutable]RawBufferPointer`.

Any array could be viewed as `UnsafeRawBufferPointer`, and that raw
view of the bytes could be used by any interface that expects a
collection of `UInt8`. An new array method `withUnsafeBytes` could
expose this raw view of the array as a sequence of bytes as follows:

```swift
let intArray = [1, 2, 3]
var byteBuffer = [UInt8]()

intArray.withUnsafeBytes {

  byteBuffer += $0
  
  assert(byteBuffer[0..<4] == [1, 0, 0, 0])

  for (i, b) in $0.enumerated() {
    assert(b == byteBuffer[i])
  }
}
```

Any data type could be safely passed to APIs that work with raw memory
via `UnsafeRawBufferPointer`, such as output streams and flat
buffers. A new `withUnsafeBytes` function could view a value as a
sequence of bytes as follows:

```swift
func write(bytes: UnsafeRawBufferPointer) { ... }

// imported struct Header
struct Header {...}

var header = Header(...)

withUnsafeBytes(of: &header) {
  write(bytes: $0)
}
```

Data of any type could be loaded from raw memory that was constructed as
an array of `UInt8`:

```swift
func readHeader(fromBytes bytes: UnsafeRawBufferPointer) -> Header {
  return bytes.load(as: Header.self)
}

let array: [UInt8] = ...
let header = array.withUnsafeBytes {
  readHeader(fromBytes: $0)
}
```

Foundation `Data` already provides high-level, safe encapsulation of
raw memory and is the common currency for passing raw memory across
framework boundaries. `Data` owns its underlying memory, provides
value semantics, and performs release-mode bounds checks. The proposed
`UnsafeRawBufferPointer` is an unowned view into an arbitrary slice of
memory. Once `UnsafeRawBufferPointer` is in place, the `Data` API can
be extended to more safely interoperate with `UnsafePointers`.

## Proposed solution

Introduce `UnsafeRawBufferPointer` and `UnsafeMutableRawBufferPointer` types, which will
respectively conform to `Collection` and `MutableCollection` of
`UInt8`. These types will provide a debug-mode bounds-checked subset of
`Unsafe[Mutable]RawPointer`'s interface to raw memory:
`load(fromByteOffset:as:)`, `storeBytes(of:toByteOffset:as:)`, and
`copyBytes(from:count:)`.

Please see the doc comments provided in [Detailed design](#detailed-design).

Add an `Array.withUnsafe[Mutable]Bytes<R>(_)` method that passes an
`UnsafeRawBufferPointer` view of the array buffer to the closure body.
    
Add a `withUnsafeMutableBytes<T, R>(of:_)` function that passes an
`UnsafeRawBufferPointer` view of a value of type `T` to the closure body.

## Migration Examples

Consider these real code migration examples:

- Network messages, see below.
- swift-package-manager/[OutputByteStream](https://github.com/apple/swift-package-manager/blob/master/Sources/Basic/OutputByteStream.swift)
- [mzaks/FlatBuffersSwift](https://github.com/mzaks/FlatBuffersSwift)
- [owensd/json-swift](https://github.com/owensd/json-swift/blob/master/src/JSValue.Parsing.swift)

This is a small sample of projects that popped up during initial
migration. As migration proceeds, more examples continue to surface
that would benefit from `UnsafeRawBufferPointer`. Ideally, code that
manages untyped memory buffers can now do so with Foundation's `Data`
API, avoiding unsafe code altogether. However, when code does drop
down the level of `UnsafePointer`, it should be natural to use the
unsafe APIs correctly. As these examples show,
`UnsafeRawBufferPointer` makes it natural to use unsafe pointers
correctly when dealing with raw bytes.

### Network Messages

This is a simplified example derived from production code encountered
during migration.

Originally, this code was reading and writing messages in a `UInt8`
buffer, then recasting an `UnsafePointer` to other data types while
decoding the message. This is undefined behavior, but was the most
reasonable way to solve the problem given existing APIs. Without
providing an alternative, developers are resorting to `unsafeBitCast`
or `assumingMemoryBound` in these cases to force code to compile,
which doesn't make the code any more correct.

This is the code after "forced" migration, without fixing memory model issues:

```swift
// Original Handler...

var handler: (Int32, [UInt8]) -> () = { _ in }

func handleMessages(_ start: UnsafePointer<UInt8>, _ count: Int) -> Int {
  var start = start
  var count = count
  while count > MemoryLayout<Int32>.size * 2 {
    let headerSize = MemoryLayout<Int32>.size * 2
    let channelID =
      Int32(unsafeBitCast(start, to: UnsafePointer<Int32>.self).pointee)
    let payloadSize =
      Int(unsafeBitCast(start.advanced(by: MemoryLayout<Int32>.size),
          to: UnsafePointer<Int32>.self).pointee)
    let totalSize = headerSize + payloadSize
    if count < totalSize {
      break
    }
    handler(channelID,
      Array<UInt8>(UnsafeBufferPointer(
        start: start.advanced(by: headerSize), count: payloadSize)))
    // Advance to the start of the next packet.
    start = start.advanced(by: totalSize)
    count -= totalSize
  }
  return count
}
```

`UnsafeRawBufferPointer` provides a convenient way to rewrite the handler and
eliminate undefined behavior:

```swift
// Updated Handler...

// imported struct Header
struct Header {
  var channel: Int32
  var payloadSize: Int32
}

var handler: (_ channel: Int32, _ bytes: UnsafeRawBufferPointer) -> () = { _, _ in }

func handleMessages(_ bytes: UnsafeRawBufferPointer) -> Int {
  var index = 0
  while true {
    let payloadIndex = index + MemoryLayout<Header>.stride
    if payloadIndex > bytes.count {
      break
    }
    let header = bytes.load(fromByteOffset: index, as: Header.self)
    index = payloadIndex + Int(header.payloadSize)
    if index > bytes.count {
      break
    }
    handler(header.channel, bytes[payloadIndex ..< index])
  }
  return bytes.count - index
}
```

Now consider the original code that calls this handler:

```swift
// Original input driver...

// imported
func read(from fd: Int32, p: UnsafeMutableRawPointer, n: Int) { ... }

func read(from fd: Int32) {
  var data: [UInt8] = []
  let tmpBufferSize = 4096
  let tmp = UnsafeMutableBufferPointer(
    start: UnsafeMutablePointer<UInt8>.allocate(capacity: tmpBufferSize),
    count: tmpBufferSize)
        
  while true {
    let result = read(self.inputFD, tmp.baseAddress, tmpBufferSize)
    assert(result >= 0)
    if result == 0 {
      break
    }
    if data.count != 0 {
      data.append(
        contentsOf: UnsafeBufferPointer(start: tmp.baseAddress, count:result))
      let remaining = data.withUnsafeBufferPointer { bufferPtr -> Int in
        return self.extractAndHandleMessages(
          bufferPtr.baseAddress!,
          bufferPtr.count)
      }
      if (remaining != data.count) {
        data = Array<UInt8>(data[data.count - remaining..<data.count])
      }
    } else {
      let remaining = self.extractAndHandleMessages(tmp.baseAddress!, result)
      if remaining != 0 {
        data = Array<UInt8>(UnsafeBufferPointer(
          start: tmp.baseAddress!.advanced(by: result - remaining),
          count:remaining))
      }
    }
  }
  tmp.baseAddress!.deallocate(capacity: tmpBufferSize)
}
```

The input driver should now be written using `UnsafeRawBufferPointer` as follows:

```swift
// Updated input driver...

// imported
func read(from fd: Int32, p: UnsafeMutableRawPointer, n: Int) { ... }

func read(from fd: Int32) throws {
  let tmpBuffer = UnsafeMutableRawBufferPointer.allocate(count: 4096)
  defer { tmpBuffer.deallocate() }

  let basePtr = tmpBuffer.baseAddress!
  var position = 0
  while true {
    let result = read(fd, basePtr + position, tmpBuffer.count - position)
    if (result < 0) {
      throw FileError()
    }
    if result == 0 {
      break
    }
    let dataBytes = UnsafeRawBufferPointer(tmpBuffer.prefix(upTo: position + result))
    let remaining = handleMessages(dataBytes)

    tmpBuffer.copyBytes(from: dataBytes.suffix(remaining))
    position = remaining
  }
}
```

On the sender side, the original post-migration code is:

```swift
// Original message send...

// imported
func write(from fd: Int32, p: UnsafeMutableRawPointer, n: Int)

private func int32ToArray(_ value: UnsafePointer<Int32>) -> [UInt8] {
  return Array<UInt8>(UnsafeBufferPointer<UInt8>(
    start: unsafeBitCast(value, to: UnsafePointer<UInt8>.self),
    count: MemoryLayout<Int32>.size))
}

func send(_ channel: Int32, _ message: [UInt8]) throws {
  var channel = channel
  var length = Int32(message.count)
  let header = int32ToArray(&channel) + int32ToArray(&length)
  header.withUnsafeBufferPointer { ptr in
    let result = write(self.outputFD, ptr.baseAddress, ptr.count)
    if result < 0 {
      throw FileError
    }
  }
  message.withUnsafeBufferPointer { ptr in
    let result = write(self.outputFD, ptr.baseAddress, ptr.count)
    if result < 0 {
      throw FileError
    }
  }
}
```

With `UnsafeRawBufferPointer`, the sender code can be written as follows:

```swift
// Updated message send...

// imported
func write(from fd: Int32, p: UnsafeMutableRawPointer, n: Int)

func send(to fd: Int32, onChannel channel: Int32, message: UnsafeRawBufferPointer) throws {
  var header = Header(channel: channel, payloadSize: Int32(message.count))
  try withUnsafeBytes(of: &header) {
    let result = write(fd, $0.baseAddress!, $0.count)
    if (result < 0) {
      throw FileError()
    }
  }
  let result = write(fd, message.baseAddress!, message.count)
  if (result < 0) {
    throw FileError()
  }
}
```

### swift-package-manager OutputByteStream

`UnsafeRawBufferPointer` is a useful tool for composing APIs like Swift package
manager's OutputByteStream which needs to operate on raw memory
independent of the type, and also needs to view that data as an array
of bytes.

Consider this current limitation of the OutputStream API:

```swift
public final class LocalFileOutputStream {
  override final func writeImpl<C: Collection>(_ bytes: C)
    where C.Iterator.Element == UInt8 {

    // FIXME: This will be copying bytes but we don't have option currently.
    var contents = [UInt8](bytes)
    while true {
      let n = fwrite(&contents, 1, contents.count, fp)
```

Instead, `UnsafeRawBufferPointer` should be the common type for data
handoff in the base class:

```swift
public class OutputByteStream {
  func writeImpl(_ bytes: UnsafeRawBufferPointer)
}
```

Without claiming this is the best architecture for this utility, we
can claim that the author should be able to implement the architecture
they have chosen correctly and without unnecessary overhead. Moving to
`UnsafeRawBufferPointer` fixes three design issues in this code that stem from
inadequate support for raw memory.

Fix #1: The public API of a high-performance utility no longer depends
on a generic type conforming to a protocol. There was no reason for
this utility to care about the type being streamed, so this was a
significant unnecessary overhead.

Fix #2: The `LocalFileOutputStream` subclass can now directly access the
bytes without copying into an array:

```swift
public final class LocalFileOutputStream {
  override final func writeImpl(_ bytes: UnsafeRawBufferPointer) {
    // Cast to a mutating raw pointer for legacy libc interop.
    let ptr = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
    while true {
      let n = fwrite(ptr, 1, contents.count, fp)
      ...
```

The `BufferedOutputByteStream` subclass can continue working with a
collection of bytes, so there's no loss in functionality:

```swift
public final class BufferedOutputByteStream: OutputByteStream {
    // FIXME: For inmemory implementation we should be share this buffer with OutputByteStream.
    // One way to do this is by allowing OuputByteStream to install external buffers.
    private var contents = [UInt8]()

  override final func writeImpl(_ bytes: UnsafeRawBufferPointer) {
    contents += bytes
  }
```

Fix #3: `OutputByteStream` can be naturally redesigned as follows to
directly access a buffer of raw memory, which is already bounds
checked and never needs to grow. A subclass like
`BufferedOutputByteStream` can continue to manage its buffer as an
array. There are no extra copies or impedance mismatch between base
class and subclass:

```swift
public class OutputByteStream {
  private var buffer: UnsafeMutableRawBufferPointer
  private var position: Int = 0

  private final var bufferedBytes: UnsafeRawBufferPointer {
    return UnsafeRawBufferPointer(buffer.prefix(upTo: position))
  }
  private var availableBufferSize: Int {
    return buffer.count - position
  }

  class var bufferSize: Int { return 1024 }

  init() {
    buffer = UnsafeMutableRawBufferPointer.allocate(count: type(of: self).bufferSize)
  }
  deinit {
    buffer.deallocate()
  }

  private func appendToBuffer(_ bytes: UnsafeRawBufferPointer) {
    buffer[position ..< position + bytes.count].copyBytes(from: bytes)
    position += bytes.count
  }

  func writeImpl(_ bytes: UnsafeRawBufferPointer) {
    fatalError("Subclasses must implement this")
  }

  public final func write(bytes: UnsafeRawBufferPointer) {
    if bytes.count > availableBufferSize {
      appendToBuffer(bytes.prefix(upTo: availableBufferSize))
      ...
    }
    ...
  }

  /// Write a sequence of bytes to the buffer.
  public final func write(_ bytes: ArraySlice<UInt8>) {
    bytes.withUnsafeBytes {
      write(bytes: $0)
    }
  }
  
  /// Write a sequence of bytes to the buffer.
  public final func write(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes {
      write(bytes: $0)
    }
  }
}

/// In-memory implementation of OutputByteStream.
public final class BufferedOutputByteStream: OutputByteStream {

  /// Default buffer size of the data buffer.
  override class var bufferSize: Int { return 0 }

  /// Contents of the stream.
  private var contents = [UInt8]()

  override public init() {
    super.init()
  }
  override final func writeImpl(_ bytes: UnsafeRawBufferPointer) {
    contents += bytes
  }
}
```

### FlatBuffers

Using `UnsafeRawBufferPointer`, the code for
[putting a value](https://github.com/mzaks/FlatBuffersSwift/blob/master/FlatBuffersSwift/FlatBufferBuilder.swift#L88)
can be correctly expressed using `UnsafeRawBufferPointer` without binding memory:

```swift
public final class FlatBufferBuilder {
  private var _data : UnsafeMutableRawBufferPointer
  var cursor = 0 // ignore left/right cursor for brevity.
  
  private var freeSpace { return _data.suffix(from: cursor) }

  public func put<T : Scalar>(value: T) {
    var v = value
    let c = MemoryLayout<T>.size
    increaseCapacity(c) // ... and align
    withUnsafeBytes(&v) {
      freeSpace.copyBytes(from: $0, count: c)
    }
    cursor += c
  }
  public func put<T : Scalar>(value: UnsafePointer<T>, length: Int) {
    increaseCapacity(length)
    let ptr = _data.baseAddress! + cursor
    freeSpace.copyBytes(from: value, count: length)
    cursor += length
  }
}
```

[FlatBufferReader](https://github.com/mzaks/FlatBuffersSwift/blob/master/FlatBuffersSwift/FlatBufferReader.swift)
can also be fixed with `UnsafeRawBufferPointer`:

```swift
public final class FlatBufferReader {
  private var _data : UnsafeRawBufferPointer

  func fromBytes<T : Scalar>(at position: Int) -> T {
    return _data.load(fromByteOffset: position, as: T.self)
  }
  public func get<T : Scalar>(objectOffset: Offset, propertyIndex: Int) -> T {
    let propertyOffset = getPropertyOffset(propertyIndex)
    let position = Int(objectOffset + propertyOffset)
    return fromBytes(at: position)
  }
}
```

### owensd/json-swift

This JSON parsing library can accept `struct Data` input [here](
https://github.com/owensd/json-swift/blob/master/src/JSValue.Parsing.swift#L23).
It then passes the bytes in data to a lower-level `parse` routine that
operates directly on UnsafeBufferPointer<UInt8>. (The library accepts
various input sources, including NSData and String, then drops down to
unsafe pointer to avoid copying). During 3.0 migration, a call to
`bindMemory(to:count:)` would need to be introduced to make it safe to
reinterpret memory as `UInt8`:

```swift
public typealias JSParsingSequence = UnsafeBufferPointer<UInt8>

public static func parse(seq: JSParsingSequence) -> JSParsingResult { ... }

public static func parse(data: ) -> JSParsingResult {
  let ptr = (data as NSData).bytes.bindMemory(to: UInt.self, count: data.length)
  let bytes = UnsafeBufferPointer<UInt8>(start: ptr, count: data.length)

  return parse(bytes)
}
```

This requires the developer to understand how the memory binding APIs
work, which is unreasonable for normal interaction with `Data`. It
also uses a deprecated interface to `Data` and has a lifetime
bug. Getting `bytes` out of `Data` should now be done using
`withUnsafeBytes`:

```swift
public func parse(_ data: Data) {
  return data.withUnsafeBytes { bytes: UnsafeBufferPointer<UInt8> in
    parse(bytes)
  }
}
```

This now implicitly binds memory, which is a big improvement. However,
there is no reason that the parser's view of memory needs to to be
typed as `UnsafeBufferPointer<UInt8>`. The JSON parser should operate
on an `UnsafeRawBufferPointer` sequence, eliminating the need to bind
memory at all. Once the `Data` interface is extended to support
calling closures that take `UnsafeRawBufferPointer`, it will be
possible to write a safer version of the code that completely avoids
binding memory:

```swift
public typealias JSParsingSequence = UnsafeRawBufferPointer

public static func parse(data: NSData) -> JSParsingResult {
  return data.withUnsafeBytes { bytes: UnsafeRawBufferPointer in
    parse(bytes)
  }
}
```

## Detailed design

```swift
% for mutable in (True, False):
%  Self = 'UnsafeMutableRawBufferPointer' if mutable else 'UnsafeRawBufferPointer'
%  Mutable = 'Mutable' if mutable else ''

/// A non-owning view over a region of memory as a Collection of bytes
/// independent of the type of values held in that memory. Each 8-bit byte in
/// memory is viewed as a `UInt8` value.
///
/// Reads and writes on memory via `UnsafeRawBufferPointer` are untyped
/// operations. Accessing this Collection's bytes does not bind the
/// underlying memory to `UInt8`. The underlying memory must be bound
/// to some trivial type whenever it is accessed via a typed operation.
///
/// - Note: A trivial type can be copied with just a bit-for-bit
///   copy without any indirection or reference-counting operations.
///   Generally, native Swift types that do not contain strong or
///   weak references or other forms of indirection are trivial, as
///   are imported C structs and enums.
///
/// In addition to the `Collection` interface, the following subset of
/// `Unsafe${Mutable}RawPointer`'s interface to raw memory is
/// provided with debug mode bounds checks:
/// - `load(fromByteOffset:as:)`,
%  if mutable:
/// - `storeBytes(of:toByteOffset:as:)`
/// - `copyBytes(from:count:)`
%  end
///
/// This is only a view into memory and does not own the memory. Copying a value
/// of type `Unsafe${Mutable}RawBufferPointer` does not copy the underlying
/// memory. However, initialiing another collection, such as `[UInt8]`, with an
/// `Unsafe${Mutable}RawBufferPointer` into copies bytes out of memory.
///
/// Example:
/// ```swift
///   // View a slice of memory at someBytes. Nothing is copied.
///   var destBytes = someBytes[0..<n]
///
///   // Copy the slice of memory into a buffer of UInt8.
///   var byteArray = [UInt8](destBytes)
///
///   // Copy another slice of memory into the buffer.
///   byteArray += someBytes[n..<m]
/// ```
///
%  if mutable:
/// And assigning into a range of subscripts copies bytes into the memory.
///
/// Example (continued):
/// ```swift
///   // Copy a another slice of memory back into the original slice.
///   destBytes[0..<n] = someBytes[m..<(m+n)]
/// ```
///
%  end
/// TODO: Specialize `index` and `formIndex` and
/// `_failEarlyRangeCheck` as in `UnsafeBufferPointer`.
public struct Unsafe${Mutable}RawBufferPointer
  : ${Mutable}Collection, RandomAccessCollection {

  public typealias Index = Int
  public typealias IndexDistance = Int
  public typealias SubSequence = ${Self}

  /// An iterator for the bytes referenced by `${Self}`.
  public struct Iterator : IteratorProtocol, Sequence {

    /// Advances to the next byte and returns it, or `nil` if no next byte
    /// exists.
    ///
    /// Once `nil` has been returned, all subsequent calls return `nil`.
    public mutating func next() -> UInt8? {
      if _position == _end { return nil }
      
      let result = _position!.load(as: UInt8.self)
      _position! += 1
      return result
    }

    internal var _position, _end: UnsafeRawPointer?
  }

%  if mutable:
  /// Allocate memory for `size` bytes with word alignment.
  ///
  /// - Postcondition: The memory is allocated, but not initialized.
  public static func allocate(count size: Int) -> UnsafeMutableRawBufferPointer {
    return UnsafeMutableRawBufferPointer(
      start: UnsafeMutableRawPointer.allocate(
        bytes: size, alignedTo: MemoryLayout<UInt>.alignment),
      count: size)
  }
%  end # mutable

  /// Deallocate this memory allocated for `bytes` number of bytes.
  ///
  /// - Precondition: The memory is not initialized.
  ///
  /// - Postcondition: The memory has been deallocated.
  public func deallocate() {
    _position?.deallocate(
      bytes: count, alignedTo: MemoryLayout<UInt>.alignment)
  }

  /// Reads raw bytes from memory at `self + offset` and constructs a
  /// value of type `T`.
  ///
  /// - Precondition: `offset + MemoryLayout<T>.size < self.count`
  ///
  /// - Precondition: The underlying pointer plus `offset` is properly
  ///   aligned for accessing `T`.
  ///
  /// - Precondition: The memory is initialized to a value of some type, `U`,
  ///   such that `T` is layout compatible with `U`.
  public func load<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T {
    _debugPrecondition(offset >= 0, "${Self}.load with negative offset")
    _debugPrecondition(offset + MemoryLayout<T>.size <= self.count,
      "${Self}.load out of bounds")
    return baseAddress!.load(fromByteOffset: offset, as: T.self)
  }

%  if mutable:
  /// Stores a value's bytes into raw memory at `self + offset`.
  ///  
  /// - Precondition: `offset + MemoryLayout<T>.size < self.count`
  ///
  /// - Precondition: The underlying pointer plus `offset` is properly
  ///   aligned for storing type `T`.
  ///
  /// - Precondition: `T` is a trivial type.
  ///
  /// - Precondition: The memory is uninitialized, or initialized to
  ///   some trivial type `U` such that `T` and `U` are mutually layout
  ///   compatible.
  /// 
  /// - Postcondition: The memory is initialized to raw bytes. If the
  ///   memory is bound to type `U`, then it now contains a value of
  ///   type `U`.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit
  ///   copy without any indirection or reference-counting operations.
  ///   Generally, native Swift types that do not contain strong or
  ///   weak references or other forms of indirection are trivial, as
  ///   are imported C structs and enums.
  public func storeBytes<T>(
    of value: T, toByteOffset offset: Int = 0, as: T.Type
  ) {
    _debugPrecondition(offset >= 0, "${Self}.storeBytes with negative offset")
    _debugPrecondition(offset + MemoryLayout<T>.size <= self.count,
      "${Self}.storeBytes out of bounds")

    baseAddress!.storeBytes(of: value, toByteOffset: offset, as: T.self)
  }

  /// Copies `count` bytes from `source` into memory at `self`.
  ///  
  /// - Precondition: `count` is non-negative.
  ///
  /// - Precondition: The memory at `source..<source + count` is
  ///   initialized to some trivial type `T`.
  ///
  /// - Precondition: If the memory at `self..<self+count` is bound to
  ///   a type `U`, then `U` is a trivial type, the underlying
  ///   pointers `source` and `self` are properly aligned for type
  ///   `U`, and `count` is a multiple of `MemoryLayout<U>.stride`.
  ///
  /// - Postcondition: The memory at `self..<self+count` is
  ///   initialized to raw bytes. If the memory is bound to type `U`,
  ///   then it contains values of type `U`.
  public func copyBytes(from source: UnsafeRawBufferPointer) {
    _debugPrecondition(source.count <= self.count,
      "${Self}.copyBytes source has too many elements")
    baseAddress?.copyBytes(from: source.baseAddress!, count: source.count)
  }

  public func copyBytes<C : Collection>(from source: C
  ) where C.Iterator.Element == UInt8 {
    _debugPrecondition(numericCast(source.count) <= self.count,
      "${Self}.copyBytes source has too many elements")
    guard let position = _position else {
      return
    }
    for (index, byteValue) in source.enumerated() {
      position.storeBytes(
        of: byteValue, toByteOffset: index, as: UInt8.self)
    }
  }
%  end # mutable

  /// Creates `${Self}` over the `count` contiguous bytes beginning at `start`.
  ///
  /// If `start` is nil, `count` must be 0. However, `count` may be 0 even for
  /// a nonzero `start`.
  public init(start: Unsafe${Mutable}RawPointer?, count: Int) {
    _precondition(count >= 0, "${Self} with negative count")
    _precondition(count == 0 || start != nil,
      "${Self} has a nil start and nonzero count")
    _position = start
    _end = start.map { $0 + count }
  }

  /// Creates `${Self}` over the contiguous bytes in `buffer`.
  ///
  /// - Precondition: `T` is a trivial type.
  public init<T>(_ buffer: UnsafeMutableBufferPointer<T>) {
    self.init(start: buffer.baseAddress!,
      count: buffer.count * MemoryLayout<T>.stride)
  }

%  if mutable:
  /// Converts UnsafeRawBufferPointer to UnsafeMutableRawBufferPointer.
  public init(mutating bytes: UnsafeRawBufferPointer) {
    self.init(start: UnsafeMutableRawPointer(mutating: bytes.baseAddress),
      count: bytes.count)
  }
%  else:
  /// Converts UnsafeMutableRawBufferPointer to UnsafeRawBufferPointer.
  public init(_ bytes: UnsafeMutableRawBufferPointer) {
    self.init(start: bytes.baseAddress, count: bytes.count)
  }

  /// Creates an `${Self}` view over the contiguous memory in `buffer`.
  ///
  /// - Precondition: `T` is a trivial type.
  public init<T>(_ buffer: UnsafeBufferPointer<T>) {
    self.init(start: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
      count: buffer.count * MemoryLayout<T>.stride)
  }
%  end # !mutable

  /// Always zero, which is the index of the first byte in a
  /// non-empty buffer.
  public var startIndex: Int {
    return 0
  }

  /// The "past the end" position---that is, the position one greater than the
  /// last valid subscript argument.
  ///
  /// The `endIndex` property of an `Unsafe${Mutable}RawBufferPointer` instance is
  /// always identical to `count`.
  public var endIndex: Int {
    return count
  }

  public typealias Indices = CountableRange<Int>

  public var indices: Indices {
    return startIndex..<endIndex
  }

  /// Accesses the `i`th byte in the memory region as a `UInt8` value.
  public subscript(i: Int) -> UInt8 {
    get {
      _debugPrecondition(i >= 0)
      _debugPrecondition(i < endIndex)
      return _position!.load(fromByteOffset: i, as: UInt8.self)
    }
%  if mutable:
    nonmutating set {
      _debugPrecondition(i >= 0)
      _debugPrecondition(i < endIndex)
      _position!.storeBytes(of: newValue, toByteOffset: i, as: UInt8.self)
    }
%  end # mutable
  }

  /// Accesses the bytes in the memory region within `bounds` as a `UInt8`
  /// values.
  public subscript(bounds: Range<Int>) -> Unsafe${Mutable}RawBufferPointer {
    get {
      _debugPrecondition(bounds.lowerBound >= startIndex)
      _debugPrecondition(bounds.upperBound <= endIndex)
      return Unsafe${Mutable}RawBufferPointer(
        start: baseAddress.map { $0 + bounds.lowerBound },
        count: bounds.count)
    }
%  if mutable:
    nonmutating set {
      _debugPrecondition(bounds.lowerBound >= startIndex)
      _debugPrecondition(bounds.upperBound <= endIndex)
      _debugPrecondition(bounds.count == newValue.count)

      if newValue.count > 0 {
        (baseAddress! + bounds.lowerBound).copyBytes(
          from: newValue.baseAddress!,
          count: newValue.count)
      }
    }
%  end # mutable
  }

  /// Returns an iterator over the bytes of this sequence.
  ///
  /// - Complexity: O(1).
  public func makeIterator() -> Iterator {
    return Iterator(_position: _position, _end: _end)
  }

  /// A pointer to the first byte of the buffer.
  public var baseAddress: Unsafe${Mutable}RawPointer? {
    return _position
  }

  /// The number of bytes in the buffer.
  public var count: Int {
    if let pos = _position {
      return _end! - pos
    }
    return 0
  }

  let _position, _end: Unsafe${Mutable}RawPointer?
}

extension Unsafe${Mutable}RawBufferPointer : CustomDebugStringConvertible {
  /// A textual representation of `self`, suitable for debugging.
  public var debugDescription: String {
    return "${Self}"
      + "(start: \(_position.map(String.init(describing:)) ?? "nil"), count: \(count))"
  }
}

/// Invokes `body` with an `${Self}` argument and returns the
/// result.
%  if mutable:
public func withUnsafeMutableBytes<T, Result>(
  of arg: inout T,
  _ body: (UnsafeMutableRawBufferPointer) throws -> Result
) rethrows -> Result
{
  return try withUnsafeMutablePointer(to: &arg) {
    return try body(UnsafeMutableRawBufferPointer(
        start: $0, count: MemoryLayout<T>.size))
  }
}
%  else:
public func withUnsafeBytes<T, Result>(
  of arg: inout T,
  _ body: (UnsafeRawBufferPointer) throws -> Result
) rethrows -> Result
{
  return try withUnsafePointer(to: &arg) {
    try body(UnsafeRawBufferPointer(start: $0, count: MemoryLayout<T>.size))
  }
}
%  end # mutable

% end # for mutable

% for Self in ['ContiguousArray', 'ArraySlice', 'Array']:

extension ${Self} {
  /// Calls a closure with a view of the array's underlying bytes of memory as a
  /// Collection of `UInt8`.
  /// ${contiguousCaveat}
  ///
  /// - Precondition: `Pointee` is a trivial type.
  ///
  /// The following example shows how you copy bytes into an array:
  ///
  ///    var numbers = [Int32](repeating: 0, count: 2)
  ///    var byteValues: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]
  ///    numbers.withUnsafeMutableBytes { destBytes in
  ///      byteValues.withUnsafeBytes { srcBytes in
  ///        destBytes.copyBytes(from: srcBytes)
  ///      }
  ///    }
  ///
  /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter that points to
  /// the contiguous storage for the array. If `body` has a return value, it is
  /// used as the return value for the `withUnsafeBytes(_:)` method. The
  /// argument is valid only for the duration of the closure's execution.
  /// - Returns: The return value of the `body` closure parameter, if any.
  ///
  /// - SeeAlso: `withUnsafeBytes`, `UnsafeRawBufferPointer`
  public mutating func withUnsafeMutableBytes<R>(
    _ body: (UnsafeMutableRawBufferPointer) throws -> R
  ) rethrows -> R {
    return try self.withUnsafeMutableBufferPointer {
      return try body(UnsafeMutableRawBufferPointer($0))
    }
  }

  /// Calls a closure with a view of the array's underlying bytes of memory as a
  /// Collection of `UInt8`.
  /// ${contiguousCaveat}
  ///
  /// - Precondition: `Pointee` is a trivial type.
  ///
  /// The following example shows how you copy the contents of an array into a
  /// buffer of `UInt8`:
  ///
  ///    let numbers = [1, 2, 3]
  ///    var byteBuffer = [UInt8]()
  ///    numbers.withUnsafeBytes {
  ///        byteBuffer += $0
  ///    }
  ///
  /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter that points to
  /// the contiguous storage for the array. If `body` has a return value, it is
  /// used as the return value for the `withUnsafeBytes(_:)` method. The
  /// argument is valid only for the duration of the closure's execution.
  /// - Returns: The return value of the `body` closure parameter, if any.
  ///
  /// - SeeAlso: `withUnsafeBytes`, `UnsafeRawBufferPointer`
  public func withUnsafeBytes<R>(
    _ body: (UnsafeRawBufferPointer) throws -> R
  ) rethrows -> R {
    return try self.withUnsafeBufferPointer {
      try body(UnsafeRawBufferPointer($0))
    }
  }
}
%end
```

## Implementation status

This proposal is fully implemented on my
[unsafebytes branch](https://github.com/atrick/swift/commits/unsafebytes)

## Impact on existing code

None

## Alternatives considered

Expect developers to continue using `[UInt8]` as type-erased buffers
but rebind memory each time they cross API boundaries.

Expect developers to convert to UnsafeRawPointer without a solution
for viewing the raw data as a collection of bytes.

There is no alternative to introducing an `UnsafeRawBufferPointer` API that
doesn't require developers to understand the subtle semantics of raw
pointers and binding memory to a type. My experience helping
developers migrate their code, which they likely did not write in the
first place, shows that this is an unreasonable expectation.
