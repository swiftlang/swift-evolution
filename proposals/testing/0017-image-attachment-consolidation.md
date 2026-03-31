# Consolidate Swift Testing's image attachments API across platforms

* Proposal: [ST-0017](0017-image-attachment-consolidation.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Rachel Brindle](https://github.com/younata)
* Status: **Implemented (Swift 6.3)**
* Implementation: [swiftlang/swift-testing#1359](https://github.com/swiftlang/swift-testing/pull/1359)
* Review: ([pitch](https://forums.swift.org/t/pitch-adjustments-to-image-attachments-in-swift-testing/82581), [review](https://forums.swift.org/t/st-0017-consolidate-swift-testing-s-image-attachments-api-across-platforms/82815), [acceptance](https://forums.swift.org/t/accepted-st-0017-consolidate-swift-testing-s-image-attachments-api-across-platforms/83045))

## Introduction

This proposal includes a small number of adjustments to the API surface of Swift
Testing's image attachments feature introduced in [ST-0014](0014-image-attachments-in-swift-testing-apple-platforms.md)
and [ST-0015](0015-image-attachments-in-swift-testing-windows.md).

## Motivation

These changes will help to align the platform-specific interfaces of the feature
more closely.

## Proposed solution

The `AttachableAsCGImage` and `AttachableAsIWICBitmapSource` protocols are
combined into a single protocol, `AttachableAsImage` with adjusted protocol
requirements; a change is made to `AttachableImageFormat` to more closely
align its interface between Darwin and Windows; `AttachableImageFormat` is made
to conform to `Equatable` and `Hashable`; and an additional property is added to
`Attachment` to query its image format.

## Detailed design

The following changes are proposed:

### Combining AttachableAsCGImage and AttachableAsIWICBitmapSource

The `AttachableAsCGImage` and `AttachableAsIWICBitmapSource` protocols are
combined into a single protocol, `AttachableAsImage`.

These platform-specific requirements are removed:

```diff
- var attachableCGImage: CGImage { get throws }
- func copyAttachableIWICBitmapSource() throws -> UnsafeMutablePointer<IWICBitmapSource>
```

They are replaced with a new requirement that encapsulates the image encoding
operation. This requirement is implemented by the CoreGraphics and WinSDK
overlays and is made publicly available for test authors who wish to declare
additional conformances to this protocol for types that are not based on
`CGImage` or `IWICBitmapSource`:

```swift
public protocol AttachableAsImage {
  // ...
  
  /// Encode a representation of this image in a given image format.
  ///
  /// - Parameters:
  ///   - imageFormat: The image format to use when encoding this image.
  ///   - body: A function to call. A temporary buffer containing a data
  ///     representation of this instance is passed to it.
  ///
  /// - Returns: Whatever is returned by `body`.
  ///
  /// - Throws: Whatever is thrown by `body`, or any error that prevented the
  ///   creation of the buffer.
  ///
  /// The testing library uses this function when saving an image as an
  /// attachment. The implementation should use `imageFormat` to determine what
  /// encoder to use.
  borrowing func withUnsafeBytes<R>(as imageFormat: AttachableImageFormat, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R
}
```

If a developer has an image type that should conform to `AttachableAsImage` and
wraps an instance of `CGImage` or `IWICBitmapSource`, it is straightforward for
them to delegate to that object. For example:

```swift
import Testing
import CoreGraphics

struct MyImage {
  var cgImage: CGImage
  // ...
}

extension MyImage: AttachableAsImage {
  func withUnsafeBytes<R>(as imageFormat: AttachableImageFormat, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
    try cgImage.withUnsafeBytes(as: imageFormat, body)
  }
}
```

### Adjusting AttachableImageFormat

The following Apple-specific `AttachableImageFormat` initializer is renamed so
that its first argument has an explicit label:

```diff
 public struct AttachableImageFormat {
   // ...
-  public init(_ contentType: UTType, encodingQuality: Float = 1.0)
+  public init(contentType: UTType, encodingQuality: Float = 1.0)
 }
```

This change makes the type's interface more consistent between Darwin and
Windows (where it has an `init(encoderCLSID:encodingQuality:)` initializer.)

As well, conformances to `Equatable`, `Hashable`, `CustomStringConvertible`, and
`CustomDebugStringConvertible` are added:

```swift
extension AttachableImageFormat: Equatable, Hashable {}
extension AttachableImageFormat: CustomStringConvertible, CustomDebugStringConvertible {}
```

Conformance to `Equatable` is necessary to correctly implement the
`withUnsafeBytes(as:_:)` protocol requirement mentioned above, and conformance
to `Hashable` is generally useful and straightforward to implement. Conformance
to `CustomStringConvertible` and `CustomDebugStringConvertible` allows for
better diagnostic output (especially if an encoding failure occurs.)

### Adding an imageFormat property to Attachment

The following property is added to `Attachment` when the attachable value is an
image:

```swift
extension Attachment where AttachableValue: AttachableWrapper,
                           AttachableValue.Wrapped: AttachableAsImage {
  /// The image format to use when encoding the represented image.
  public var imageFormat: AttachableImageFormat? { get }
}
```

## Source compatibility

These changes are breaking for anyone who has created a type that conforms to
either `AttachableAsCGImage` or `AttachableAsIWICBitmapSource`, or anyone who
has adopted `AttachableImageFormat.init(_:encodingQuality:)`.

This feature is new in Swift 6.3 and has not shipped to developers outside of
nightly toolchain builds. As such, we feel confident that any real-world impact
to developers will be both minimal and manageable.

## Integration with supporting tools

No changes.

## Future directions

- Migrating from `UnsafeRawBufferPointer` to `RawSpan`. We shipped the initial
  attachments feature using `UnsafeRawBufferPointer` before `RawSpan` was
  available and, in particular, before it was back-deployed to earlier Apple
  platforms. We want the attachments API to consistently use the same types at
  all layers, so adoption of `RawSpan` only in the image attachments layer is a
  non-goal. In the future, we may wish to deprecate the existing APIs that use
  `UnsafeRawBufferPointer` and introduce replacements that use `RawSpan`.

## Alternatives considered

- Leaving the two protocols separate. Combining them allows us to lower more
  code into the main Swift Testing library and improves our ability to generate
  DocC documentation, while also simplifying the story for developers who want
  to use this feature across platforms.

## Acknowledgments

Thanks to my colleagues for their feedback on the image attachments feature and
to the Swift community for putting up with the churn!
