# Image attachments in Swift Testing

* Proposal: [ST-NNNN](NNNN-cgimage-attachments.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: rdar://154869058
* Implementation: [swiftlang/swift-testing#827](https://github.com/swiftlang/swift-testing/pull/827), _et al._ <!-- jgrynspan/image-attachments has additional conformances -->
* Review: ([pitch](https://forums.swift.org/t/pitch-image-attachments-in-swift-testing/80867))

## Introduction

We introduced the ability to add attachments to tests in Swift 6.2. This
proposal augments that feature to support attaching images on Apple platforms.

## Motivation

It is frequently useful to be able to attach images to tests for engineers to
review, e.g. if a UI element is not being drawn correctly.
<!-- TODO: add more motivation detail -->

## Proposed solution

We propose adding support for _images_ as a category of Swift type that can be
encoded using standard graphics formats such as JPEG or PNG. Image serialization
is beyond the purview of the testing library, so Swift Testing will defer to the
operating system to provide the relevant functionality. As such, this proposal
covers support for **Apple platforms** only. Support for other platforms such as
Windows is discussed in the **Future directions** section of this proposal.

## Detailed design

A new protocol is introduced for Apple platforms:

```swift
/// A protocol describing images that can be converted to instances of
/// ``Testing/Attachment``.
///
/// Instances of types conforming to this protocol do not themselves conform to
/// ``Testing/Attachable``. Instead, the testing library provides additional
/// initializers on ``Testing/Attachment`` that take instances of such types and
/// handle converting them to image data when needed.
///
/// The following system-provided image types conform to this protocol and can
/// be attached to a test:
///
/// - [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage)
/// - [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage)
/// - [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage)
///   (macOS)
/// - [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage)
///   (iOS, watchOS, tvOS, visionOS, and Mac Catalyst)
///
/// You do not generally need to add your own conformances to this protocol. If
/// you have an image in another format that needs to be attached to a test,
/// first convert it to an instance of one of the types above.
public protocol AttachableAsCGImage {
  /// An instance of `CGImage` representing this image.
  ///
  /// - Throws: Any error that prevents the creation of an image.
  var attachableCGImage: CGImage { get throws }
}
```

And conformances are provided for the following types:

- [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage)
- [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage)
- [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage)
  (macOS)
- [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage)
  (iOS, watchOS, tvOS, visionOS, and Mac Catalyst)

The implementation of `CGImage.attachableCGImage` simply returns `self`, while
the other implementations extract an underlying `CGImage` instance if available
or render one on-demand.

> [!NOTE]
> Apple may opt to provide support for additional platform-specific types in
> their fork of the Swift project. Such functionality is beyond the scope of
> this proposal.

New overloads of `Attachment.init()` and `Attachment.record()` are provided:

```swift
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension Attachment {
  /// Initialize an instance of this type that encloses the given image.
  ///
  /// - Parameters:
  ///   - attachableValue: The value that will be attached to the output of
  ///     the test run.
  ///   - preferredName: The preferred name of the attachment when writing it
  ///     to a test report or to disk. If `nil`, the testing library attempts
  ///     to derive a reasonable filename for the attached value.
  ///   - contentType: The image format with which to encode `attachableValue`.
  ///   - encodingQuality: The encoding quality to use when encoding the image.
  ///     For the lowest supported quality, pass `0.0`. For the highest
  ///     supported quality, pass `1.0`.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// The following system-provided image types conform to the
  /// ``AttachableAsCGImage`` protocol and can be attached to a test:
  ///
  /// - [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage)
  /// - [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage)
  /// - [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage)
  ///   (macOS)
  /// - [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage)
  ///   (iOS, watchOS, tvOS, visionOS, and Mac Catalyst)
  ///
  /// The testing library uses the image format specified by `contentType`. Pass
  /// `nil` to let the testing library decide which image format to use. If you
  /// pass `nil`, then the image format that the testing library uses depends on
  /// the path extension you specify in `preferredName`, if any. If you do not
  /// specify a path extension, or if the path extension you specify doesn't
  /// correspond to an image format the operating system knows how to write, the
  /// testing library selects an appropriate image format for you.
  ///
  /// If the target image format does not support variable-quality encoding,
  /// the value of the `encodingQuality` argument is ignored. If `contentType`
  /// is not `nil` and does not conform to [`UTType.image`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/image),
  /// the result is undefined.
  public init<T>(
    _ attachableValue: T,
    named preferredName: String? = nil,
    as contentType: UTType? = nil,
    encodingQuality: Float = 1.0,
    sourceLocation: SourceLocation = #_sourceLocation
  ) where AttachableValue == _AttachableImageWrapper<T>

  /// Attach an image to the current test.
  ///
  /// - Parameters:
  ///   - image: The value to attach.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk. If `nil`, the testing library attempts to
  ///     derive a reasonable filename for the attached value.
  ///   - contentType: The image format with which to encode `attachableValue`.
  ///   - encodingQuality: The encoding quality to use when encoding the image.
  ///     For the lowest supported quality, pass `0.0`. For the highest
  ///     supported quality, pass `1.0`.
  ///   - sourceLocation: The source location of the call to this function.
  ///
  /// This function creates a new instance of ``Attachment`` wrapping `image`
  /// and immediately attaches it to the current test.
  ///
  /// The following system-provided image types conform to the
  /// ``AttachableAsCGImage`` protocol and can be attached to a test:
  ///
  /// - [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage)
  /// - [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage)
  /// - [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage)
  ///   (macOS)
  /// - [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage)
  ///   (iOS, watchOS, tvOS, visionOS, and Mac Catalyst)
  ///
  /// The testing library uses the image format specified by `contentType`. Pass
  /// `nil` to let the testing library decide which image format to use. If you
  /// pass `nil`, then the image format that the testing library uses depends on
  /// the path extension you specify in `preferredName`, if any. If you do not
  /// specify a path extension, or if the path extension you specify doesn't
  /// correspond to an image format the operating system knows how to write, the
  /// testing library selects an appropriate image format for you.
  ///
  /// If the target image format does not support variable-quality encoding,
  /// the value of the `encodingQuality` argument is ignored. If `contentType`
  /// is not `nil` and does not conform to [`UTType.image`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/image),
  /// the result is undefined.
  public static func record<T>(
    _ image: consuming T,
    named preferredName: String? = nil,
    as contentType: UTType? = nil,
    encodingQuality: Float = 1.0,
    sourceLocation: SourceLocation = #_sourceLocation
  ) where AttachableValue == _AttachableImageWrapper<T>
}
```

> [!NOTE]
> `_AttachableImageWrapper` is an implementation detail required by Swift's
> generic type system and is not itself part of this proposal. For completeness,
> its public interface is:
>
> ```swift
> @available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
> public struct _AttachableImageWrapper<Image>: Sendable, AttachableWrapper where Image: AttachableAsCGImage {
>   public var wrappedValue: Image { get set }
> }
> ```

A developer may then easily attach an image to a test by calling
`Attachment.record()` and passing the image of interest. For example, to attach
a rendering of a SwiftUI view:

```swift
import Testing
import UIKit
import SwiftUI

@MainActor @Test func `attaching a SwiftUI view as an image`() throws {
  let myView: some View = ...
  let image = try #require(ImageRenderer(content: myView).uiImage)
  Attachment.record(image, named: "my view")
}
```

## Source compatibility

This change is additive only.

## Integration with supporting tools

None needed.

## Future directions

- Adding support for Windows image types such as [`HBITMAP`](https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-images-bitmaps-and-metafiles-about).
  This is definitely of interest to us but is, broadly speaking, incompatible
  with Apple's image APIs and will require a separate proposal. We expect
  support for Windows to take the form of a separate protocol, tentatively named
  `AttachableAsGDIPlusImage`:

  ```swift
  protocol AttachableAsGDIPlusImage {
    var gdiPlusImage: WinSDK.Gdiplus.Image { get throws }
  }
  ```

  GDI+ uses `CLSID` to represent different encoders (i.e. image formats), so we
  would want to provide a type that can accommodate arbitrary `CLSID` values as
  well as provide easy access to common image formats:

  ```swift
  struct AttachableImageFormat: ~Copyable {
    init(_ clsid: consuming CLSID)
    init?(mimeType: String)

    static var png: { yielding borrow }
    static var jpeg: { yielding borrow }
    ...
  }
  ```

  The rest of the interface would otherwise look similar to the one proposed in
  this document.

- Adding support for X11-compatible image types such as Qt's [`QImage`](https://doc.qt.io/qt-6/qimage.html).
  We're also interested in implementing something here, but GUI-level libraries
  aren't guaranteed to be present on Linux systems, so we cannot rely on their
  headers or modules being accessible while building the Swift toolchain. It may
  be appropriate to roll such functionality into a hypothetical `swift-x11`,
  `swift-wayland`, `swift-qt`, etc. package if one is ever created.

- Adding support for rendering to a PDF instead of an image. While technically
  feasible using existing Core Graphics API, we haven't identified sufficient
  demand for this functionality.

## Alternatives considered

- Doing nothing. Developers would need to write their own image conversion code.
  Since this is a very common operation, it makes sense to incorporate it into
  Swift Testing directly.

- Making `CGImage` etc. conform directly to `Attachable`. Doing so would
  prevent us from including sidecar data such as the desired `UTType` or
  encoding quality as these types do not provide storage for that information.
  As well, `NSImage` does not conform to `Sendable` and would be forced down a
  code path that eagerly serializes it, which could pessimize its performance
  once we introduce attachment lifetimes in a future proposal.

- Designing a platform-agnostic solution. This would likely require adding a
  dependency on an open-source image package such as [ImageMagick](https://github.com/ImageMagick/ImageMagick).
  While we appreciate the value of such libraries and we want Swift Testing to
  be as portable as possible, that would be a significant new dependency for the
  testing library and the Swift toolchain at large. As well, we expect a typical
  use case to involve an instance of `NSImage`, `CGImage`, etc.

- Designing a solution that does not require `UTType` so as to support earlier
  Apple platforms. The implementation is based on Apple's ImageIO framework
  which requires a Uniform Type Identifier as input anyway, and the older
  `CFString`-based interfaces we would need to use have been deprecated for
  several years now.

- Designing a solution based around _drawing_ into a `CGContext` rather than
  acquiring an instance of `CGImage`. If the proposed protocol looked like:

  ```swift
  protocol AttachableByDrawing {
    func draw(in context: CGContext, for attachment: Attachment<Self>) throws
  }
  ```

  It would be easier to support alternative destination contexts (primarily PDF
  contexts), but we would need to make a complete copy of an image in memory
  before serializing it. If you start with an instance of `CGImage` or an object
  that wraps an instance of `CGImage`, you can pass it directly to ImageIO.

## Acknowledgments

Thanks to Apple's testing teams and to the Testing Workgroup for their support
and advice on this project.
