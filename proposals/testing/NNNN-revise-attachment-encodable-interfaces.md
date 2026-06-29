# Revise Swift Testing's `Attachment`/`Encodable` interop

* Proposal: [ST-NNNN](NNNN-revise-attachment-encodable-interfaces.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#1770](https://github.com/swiftlang/swift-testing/pull/1770)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

We introduced **attachments** to Swift Testing in Swift 6.2 with [ST-0009][].
As part of that initial introduction, we included default implementations of our
[`Attachable`][] protocol's requirements for types that already conform to
[`Encodable`][] or [`NSSecureCoding`][].

This proposal revises the interfaces for attaching a value that conforms to one
of those protocols to resolve some constraints that come with the current
interface and implementation.

## Motivation

We have identified several deficiencies in the current interface:

- Test authors must explicitly add conformance to [`Attachable`][] to their
  types that already conform to [`Encodable`][] or [`NSSecureCoding`][], which
  is boilerplate that doesn't really _do_ anything other than satisfy Swift's
  type system.
- The only way to select between property list and JSON encodings is to specify
  a path extension in the attachment's preferred name.
- There is no way to customize the encoder's settings. For example, there is no
  way to configure [`JSONEncoder.outputFormatting`](https://developer.apple.com/documentation/foundation/jsonencoder/outputformatting-swift.property).
- Types that conform to _both_ [`Encodable`][] and [`NSSecureCoding`][] are
  ambiguously encoded. We document these types as using the [`Encodable`][]
  encoding by default, but there is no way to customize this behavior.

## Proposed solution

New [`Attachment`][] initializers are introduced that behave similarly to the
initializers introduced for file URLs in [ST-0009][] and for [`Transferable`][]-conforming
types in [ST-0023][].

The existing default implementations of [`Attachable`][]'s requirements are
marked to-be-deprecated. Their documentation will automatically include
migration information, but new diagnostics will not be emitted at build time
until a future Swift release.

## Detailed design

The following extension to `Attachment` is added and is available when
test authors import both `Testing` and `Foundation` in a Swift file:

```swift
extension Attachment {
  /// Initialize an instance of this type representing a value that conforms to
  /// the `Encodable` protocol.
  ///
  /// - Parameters:
  ///   - encodableValue: The value to encode and attach.
  ///   - encodingFormat: The encoding format to use to encode `encodableValue`.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// - Throws: If an appropriate encoder could not be found given the
  ///   `encodingFormat` and `preferredName` arguments.
  ///
  /// Use this initializer to create an instance of ``Attachment`` from a value
  /// that conforms to the `Encodable` protocol:
  ///
  /// let menu = FoodTruck.currentMenu
  /// let attachment = try Attachment(encoding: menu, as: .json)
  /// Attachment.record(attachment)
  ///
  /// The encoding that the testing library uses depends on the `encodingFormat`
  /// argument. If the value of that argument is `nil`, the testing library
  /// derives the format from the path extension you specify in `preferredName`.
  ///
  /// | Extension | Encoding Used | Encoder Used |
  /// |-|-|-|
  /// | `".xml"` | XML property list | `PropertyListEncoder` |
  /// | `".plist"` | Binary property list | `PropertyListEncoder` |
  /// | None, `".json"` | JSON | `JSONEncoder` |
  ///
  /// - Important: OpenStep-style property lists are not supported.
  ///
  /// If the values of both the `encodingFormat` and `preferredName` arguments
  /// are `nil`, the testing library encodes `encodableValue` as JSON.
  public init<T>(
    encoding encodableValue: T,
    as encodingFormat: AttachableEncodingFormat? = nil,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws where AttachableValue == _AttachableEncodableWrapper<T, Void>, T: Encodable

#if canImport(Combine)
  /// Initialize an instance of this type representing a value that conforms to
  /// the `Encodable` protocol.
  ///
  /// - Parameters:
  ///   - encodableValue: The value to encode and attach.
  ///   - encoder: The encoder to use to encode `encodableValue`.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// - Throws: If `encoder` cannot be used to encode `encodableValue`.
  ///
  /// Use this initializer to create an instance of ``Attachment`` from a value
  /// that conforms to the `Encodable` protocol:
  ///
  /// let menu = FoodTruck.currentMenu
  /// let encoder = JSONEncoder()
  /// let attachment = try Attachment(encoding: menu, using: encoder)
  /// Attachment.record(attachment)
  public init<T, E>(
    encoding encodableValue: T,
    using encoder: E,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws where AttachableValue == _AttachableEncodableWrapper<T, E>, T: Encodable, E: TopLevelEncoder, E.Output: ContiguousBytes
#endif

  /// Initialize an instance of this type representing a value that conforms to
  /// the `NSSecureCoding` protocol.
  ///
  /// - Parameters:
  ///   - encodableValue: The value to encode and attach.
  ///   - propertyListFormat: The property list format to use to encode
  ///     `encodableValue`.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// - Throws: If an appropriate encoder could not be found given the
  ///   `propertyListFormat` and `preferredName` arguments.
  ///
  /// Use this initializer to create an instance of ``Attachment`` from a value
  /// that conforms to the `NSSecureCoding` protocol:
  ///
  /// let menu = FoodTruck.currentMenu
  /// let attachment = try Attachment(encoding: menu, as: .xml)
  /// Attachment.record(attachment)
  ///
  /// The encoding that the testing library uses depends on the
  /// `propertyListFormat` argument. If the value of that argument is `nil`, the
  /// testing library derives the format from the path extension you specify in
  /// `preferredName`.
  ///
  /// | Extension | Encoding Used | Encoder Used |
  /// |-|-|-|
  /// | `".xml"` | XML property list | `NSKeyedArchiver` |
  /// | None, `".plist"` | Binary property list | `NSKeyedArchiver` |
  ///
  /// - Important: OpenStep-style property lists are not supported.
  ///
  /// If the values of both the `propertyListFormat` and `preferredName`
  /// arguments are `nil`, the testing library encodes `encodableValue` as a
  /// binary property list.
  public init<T>(
    encoding encodableValue: T,
    as propertyListFormat: PropertyListSerialization.PropertyListFormat? = nil,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws where AttachableValue == _AttachableEncodableWrapper<T, NSKeyedArchiver>, T: NSSecureCoding
}
```

> [!NOTE]
> The `_AttachableEncodableWrapper` is a type that conforms to the
> [`AttachableWrapper`][] protocol and is an implementation detail. Test authors
> do not need to use this type directly.

The `AttachableEncodingFormat` type is declared as follows:

```swift
/// An enumeration describing the encoding formats that you can use when
/// attaching a value that conforms to `Encodable`.
///
/// Pass an instance of this type to ``Testing/Attachment/init(encoding:as:named:sourceLocation:)``
/// to specify what encoder and format to use when the testing library saves the
/// resulting attachment.
///
/// If you want to attach a value that conforms to `NSSecureCoding`, use
/// `PropertyListFormat` instead.
public struct AttachableEncodingFormat: Sendable, Equatable {
  /// Create an instance of this type representing a property list format.
  ///
  /// - Parameters:
  ///   - format: The corresponding property list format.
  ///
  /// - Returns: An instance of this type representing `format`.
  public static func propertyListFormat(_ format: PropertyListSerialization.PropertyListFormat) -> Self

  /// An instance of this type representing the JSON format.
  public static var json: Self { get }
}
```

Test authors can use the new initializers to create attachments from any value
that conforms to [`Encodable`][] or [`NSSecureCoding`][]. These values do not
need a _pro forma_ conformance to [`Attachable`][]:

```swift
@Test func `Bake an apple pie`() throws {
  let oven = Oven()
  oven.warm(to: .fahrenheit(400))
  ...
  let attachment = try Attachment(encoding: recipe, as: .propertyListFormat(.binary))
  Attachment.record(attachment)
  ...
  #expect(pie.isDelicious)
}

// OR:

@Test func `Bake an apple pie`() throws {
  let oven = Oven()
  oven.warm(to: .fahrenheit(400))
  ...
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, ...]
  let attachment = try Attachment(encoding: recipe, using: encoder)
  Attachment.record(attachment)
  ...
  #expect(pie.isScrumptious)
}
```

If the test author does not specify an encoding format or encoder, Swift Testing
makes a best effort to derive the encoding format from the attachment's
preferred name (as with the existing interface). If the test author doesn't
specify a preferred name either, Swift Testing defaults to JSON (for [`Encodable`][]
types) or the binary property list format (for [`NSSecureCoding`][] types).

### Deprecation of existing interfaces

The existing default implementations are marked to-be-deprecated:

```swift
extension Attachable where Self: Encodable {
  /// @DeprecationSummary {
  ///   Use ``Attachment/init(encoding:as:named:sourceLocation:)`` instead:
  ///
  ///   let attachment = try Attachment(encoding: someValue, as: .json)
  ///   Attachment.record(attachment)
  /// }
  @available(swift, introduced: 6.2, deprecated: 100000.0, message: "Use 'Attachment.init(encoding:as:named:sourceLocation:)' instead")
  public func withUnsafeBytes<R>(for attachment: borrowing Attachment<Self>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R
}

extension Attachable where Self: NSSecureCoding {
  /// @DeprecationSummary {
  ///   Use ``Attachment/init(encoding:as:named:sourceLocation:)`` instead:
  ///
  ///   let attachment = try Attachment(encoding: someValue, as: .binary)
  ///   Attachment.record(attachment)
  /// }
  @available(swift, introduced: 6.2, deprecated: 100000.0, message: "Use 'Attachment.init(encoding:as:named:sourceLocation:)' instead")
  public func withUnsafeBytes<R>(for attachment: borrowing Attachment<Self>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R
}
```

### `TopLevelEncoder` on non-Apple platforms

[`TopLevelEncoder`][] is declared in the Combine framework which is part of
Apple's SDKs but not part of the open source Swift project. As such, it is not
available on non-Apple platforms. See **future directions** for more details; in
the mean time, concrete overloads of `init(encoding:using:named:sourceLocation:)`
are added on non-Apple platforms to cover the common use cases:

```swift
#if !canImport(Combine)
extension Attachment {
  public init<T, E>(
    encoding encodableValue: T,
    using encoder: E,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws where AttachableValue == _AttachableEncodableWrapper<T, E>, T: Encodable, E: PropertyListEncoder

  public init<T, E>(
    encoding encodableValue: T,
    using encoder: E,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws where AttachableValue == _AttachableEncodableWrapper<T, E>, T: Encodable, E: JSONEncoder
}
#endif
```

## Source compatibility

These changes are additive and should not impact existing code.

## Integration with supporting tools

No changes. Supporting tools that consume attachments should "just work".

## Future directions

- **Lowering [`TopLevelEncoder`][] to the standard library.** If we do this, then
  the protocol becomes available on non-Apple platforms and our hard-coded
  workarounds can be removed. (The author intends to propose a change here, but
  it is beyond the scope of _this_ proposal).

- **Formally deprecating the existing interface.** As discussed above, a future
  Swift toolchain release will emit deprecation warnings at build time when a
  type conforms to both [`Encodable`][]/[`NSSecureCoding`][] and [`Attachable`][]
  and relies on the default implementations of [`Attachable`][]'s requirements.

## Alternatives considered

- **Exposing new overloads of `Attachment.record()` instead of `Attachment.init()`.**
  See [ST-0023][] for more information why we prefer to overload `init()` here
  instead of `record()`.

- **Dropping support for [`NSSecureCoding`][].** While [`Encodable`][] is the
  preferred serialization protocol in Swift, [`NSSecureCoding`][] remains
  supported at the Foundation layer.

- **Leaving the existing interfaces undeprecated while adding the new ones.**
  The existing interfaces have the aforementioned ergonomic deficiencies. We
  don't want test authors to add conformances to [`Attachable`][] by rote, and
  we don't want to support two entirely distinct mechanisms for attaching
  encodable values when only one is needed (let alone where only one is
  _recommended_).

[`Attachable`]: https://developer.apple.com/documentation/testing/attachable
[`AttachableWrapper`]: https://developer.apple.com/documentation/testing/attachablewrapper
[`Attachment`]: https://developer.apple.com/documentation/testing/attachment
[`Encodable`]: https://developer.apple.com/documentation/swift/encodable
[`NSSecureCoding`]: https://developer.apple.com/documentation/foundation/nssecurecoding
[`TopLevelEncoder`]: https://developer.apple.com/documentation/combine/toplevelencoder
[`Transferable`]: https://developer.apple.com/documentation/coretransferable/transferable

[ST-0009]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0009-attachments.md
[ST-0023]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0023-attachments-transferable.md