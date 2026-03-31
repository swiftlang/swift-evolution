# Image attachments in Swift Testing (Apple platforms)

* Proposal: [ST-0014](0014-image-attachments-in-swift-testing-apple-platforms.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Maarten Engels](https://github.com/maartene/)
- Status: **Implemented (Swift 6.3)**
* Bug: rdar://154869058
* Implementation: [swiftlang/swift-testing#827](https://github.com/swiftlang/swift-testing/pull/827), _et al._ <!-- jgrynspan/image-attachments has additional conformances -->
* Review: ([pitch](https://forums.swift.org/t/pitch-image-attachments-in-swift-testing/80867)) ([review](https://forums.swift.org/t/st-0014-image-attachments-in-swift-testing-apple-platforms/81507)) ([acceptance](https://forums.swift.org/t/accepted-st-0014-image-attachments-in-swift-testing-apple-platforms/81868))

## Introduction

We introduced the ability to add attachments to tests in Swift 6.2. This
proposal augments that feature to support attaching images on Apple platforms.

## Motivation

It is frequently useful to be able to attach images to tests for engineers to
review, e.g. if a UI element is not being drawn correctly. If something doesn't
render correctly in a CI environment, for instance, it is very useful to test
authors to be able to download the failed rendering and examine it at-desk.

Today, Swift Testing offers support for **attachments** which allow a test
author to save arbitrary files created during a test run. However, if those
files are images, the test author must write their own code to encode them as
(for example) JPEG or PNG files before they can be attached to a test.

## Proposed solution

We propose adding support for images as a category of Swift type that can be
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
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
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
> The list of conforming types may be extended in the future. The Testing
> Workgroup will determine if additional Swift Evolution reviews are needed.

### Attaching a conforming image

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
  ///   - imageFormat: The image format with which to encode `attachableValue`.
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
  /// The testing library uses the image format specified by `imageFormat`. Pass
  /// `nil` to let the testing library decide which image format to use. If you
  /// pass `nil`, then the image format that the testing library uses depends on
  /// the path extension you specify in `preferredName`, if any. If you do not
  /// specify a path extension, or if the path extension you specify doesn't
  /// correspond to an image format the operating system knows how to write, the
  /// testing library selects an appropriate image format for you.
  public init<T>(
    _ attachableValue: T,
    named preferredName: String? = nil,
    as imageFormat: AttachableImageFormat? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) where AttachableValue == _AttachableImageWrapper<T>

  /// Attach an image to the current test.
  ///
  /// - Parameters:
  ///   - image: The value to attach.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk. If `nil`, the testing library attempts to
  ///     derive a reasonable filename for the attached value.
  ///   - imageFormat: The image format with which to encode `attachableValue`.
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
  /// The testing library uses the image format specified by `imageFormat`. Pass
  /// `nil` to let the testing library decide which image format to use. If you
  /// pass `nil`, then the image format that the testing library uses depends on
  /// the path extension you specify in `preferredName`, if any. If you do not
  /// specify a path extension, or if the path extension you specify doesn't
  /// correspond to an image format the operating system knows how to write, the
  /// testing library selects an appropriate image format for you.
  public static func record<T>(
    _ image: T,
    named preferredName: String? = nil,
    as imageFormat: AttachableImageFormat? = nil,
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
>   public var wrappedValue: Image { get }
> }
> ```

### Specifying image formats

A test author can specify the image format to use with `AttachableImageFormat`.
This type abstractly represents the destination image format and, where
applicable, encoding quality:

```swift
/// A type describing image formats supported by the system that can be used
/// when attaching an image to a test.
///
/// When you attach an image to a test, you can pass an instance of this type to
/// ``Attachment/record(_:named:as:sourceLocation:)`` so that the testing
/// library knows the image format you'd like to use. If you don't pass an
/// instance of this type, the testing library infers which format to use based
/// on the attachment's preferred name.
///
/// The PNG and JPEG image formats are always supported. The set of additional
/// supported image formats is platform-specific:
///
/// - On Apple platforms, you can use [`CGImageDestinationCopyTypeIdentifiers()`](https://developer.apple.com/documentation/imageio/cgimagedestinationcopytypeidentifiers())
///   from the [Image I/O framework](https://developer.apple.com/documentation/imageio)
///   to determine which formats are supported.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct AttachableImageFormat: Sendable {
  /// The encoding quality to use for this image format.
  ///
  /// The meaning of the value is format-specific with `0.0` being the lowest
  /// supported encoding quality and `1.0` being the highest supported encoding
  /// quality. The value of this property is ignored for image formats that do
  /// not support variable encoding quality.
  public var encodingQuality: Float { get }
}
```

Conveniences for the PNG and JPEG formats are provided as they are very widely
used and supported across almost all modern platforms, Web browsers, etc.:

```swift
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension AttachableImageFormat {
  /// The PNG image format.
  public static var png: Self { get }

  /// The JPEG image format with maximum encoding quality.
  public static var jpeg: Self { get }

  /// The JPEG image format.
  ///
  /// - Parameters:
  ///   - encodingQuality: The encoding quality to use when serializing an
  ///     image. A value of `0.0` indicates the lowest supported encoding
  ///     quality and a value of `1.0` indicates the highest supported encoding
  ///     quality.
  ///
  /// - Returns: An instance of this type representing the JPEG image format
  ///   with the specified encoding quality.
  public static func jpeg(withEncodingQuality encodingQuality: Float) -> Self
}
```

For instance, to save an image in the JPEG format with 50% image quality, you
can use `.jpeg(withEncodingQuality: 0.5)`.

On Apple platforms, a convenience initializer that takes an instance of `UTType`
is also provided and lets you select any format supported by the underlying
Image I/O framework:

```swift
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension AttachableImageFormat {
  /// The content type corresponding to this image format.
  ///
  /// The value of this property always conforms to [`UTType.image`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/image).
  public var contentType: UTType { get }

  /// Initialize an instance of this type with the given content type and
  /// encoding quality.
  ///
  /// - Parameters:
  ///   - contentType: The image format to use when encoding images.
  ///   - encodingQuality: The encoding quality to use when encoding images. For
  ///     the lowest supported quality, pass `0.0`. For the highest supported
  ///     quality, pass `1.0`.
  ///
  /// If the target image format does not support variable-quality encoding,
  /// the value of the `encodingQuality` argument is ignored.
  ///
  /// If `contentType` does not conform to [`UTType.image`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/image),
  /// the result is undefined.
  public init(_ contentType: UTType, encodingQuality: Float = 1.0)
}
```

### Example usage

A developer may then easily attach an image to a test by calling
`Attachment.record()` and passing the image of interest. For example, to attach
a rendering of a SwiftUI view as a PNG file:

```swift
import Testing
import UIKit
import SwiftUI

@MainActor @Test func `attaching a SwiftUI view as an image`() throws {
  let myView: some View = ...
  let image = try #require(ImageRenderer(content: myView).uiImage)
  Attachment.record(image, named: "my view", as: .png)
  // OR: Attachment.record(image, named: "my view.png")
}
```

## Source compatibility

This change is additive only.

## Integration with supporting tools

None needed.

## Future directions

- Adding support for [`SwiftUI.Image`](https://developer.apple.com/documentation/swiftui/image)
  and/or [`SwiftUI.GraphicsContext.ResolvedImage`](https://developer.apple.com/documentation/swiftui/graphicscontext/resolvedimage).
  These types do not directly wrap an instance of `CGImage`.

  Since `SwiftUI.Image` conforms to [`SwiftUI.View`](https://developer.apple.com/documentation/swiftui/view),
  it is possible to convert an instance of that type to an instance of `CGImage`
  using [`SwiftUI.ImageRenderer`](https://developer.apple.com/documentation/swiftui/imagerenderer).
  This approach is generalizable to all `SwiftUI.View`-cnforming types, and the
  correct approach here may be to provide an `_AttachableViewWrapper<View>`
  type similar to the described `_AttachableImageWrapper<Image>` type.

- Adding support for Windows image types. Windows has several generations of
  imaging libraries:

  - Graphics Device Interface (GDI), which shipped with the original Windows in
    1985;
  - GDI+, which was introduced with Windows XP in 2001;
  - Windows Imaging Component (WIC) with Windows Vista in 2006; and
  - Direct2D with Windows 7 in 2008.

  Of these libraries, only the original GDI provides a C interface that can be
  directly referenced from Swift. The GDI+ interface is written in C++ and the
  WIC and Direct2D interfaces are built on top of COM (a C++ abstraction layer.)
  This reliance on C++ poses challenges for Swift Testing. Swift/C++ interop is
  still a young technology and is not yet able to provide abstractions for
  virtual C++ classes.

  None of these Windows' libraries are source compatible with Apple's Core
  Graphics API, so support for any of them will require a different protocol. As
  of this writing, [an experimental](https://github.com/swiftlang/swift-testing/pull/1245)
  GDI- and (partially) GDI+-compatible protocol is available in Swift Testing
  that allows a test author to attach an image represented by an `HBITMAP` or
  `HICON` instance. Further work will be needed to make this experimental
  Windows support usable with the newer libraries' image types.

- Adding support for X11-compatible image types such as Qt's [`QImage`](https://doc.qt.io/qt-6/qimage.html)
  or GTK's [`GdkPixbuf`](https://docs.gtk.org/gdk-pixbuf/class.Pixbuf.html).
  We're also interested in implementing something here, but GUI-level libraries
  aren't guaranteed to be present on Linux systems, so we cannot rely on their
  headers or modules being accessible while building the Swift toolchain. It may
  be appropriate to roll such functionality into a hypothetical `swift-x11`,
  `swift-wayland`, `swift-qt`, `swift-gtk`, etc. package if one is ever created.

- Adding support for Android's [`android.graphics.Bitmap`](https://developer.android.com/reference/android/graphics/Bitmap)
  type. The Android NDK includes the [`AndroidBitmap_compress()`](https://developer.android.com/ndk/reference/group/bitmap#androidbitmap_compress)
  function, but proper support for attaching an Android `Bitmap` may require a
  dependency on [`swift-java`](https://github.com/swiftlang/swift-java) in some
  form. Going forward, we hope to work with the new [Android Workgroup](https://www.swift.org/android-workgroup/)
  to enhance Swift Testing's Android support.

- Adding support for rendering to a PDF instead of an image. While technically
  feasible using [existing](https://developer.apple.com/documentation/coregraphics/cgcontext/init(consumer:mediabox:_:))
  Core Graphics API, we haven't identified sufficient demand for this
  functionality.

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
  Apple platforms. The implementation is based on Apple's Image I/O framework
  which requires a Uniform Type Identifier as input anyway, and the older
  `CFString`-based interfaces we would need to use have been deprecated for
  several years now. The `AttachableImageFormat` type allows us to abstract away
  our platform-specific dependency on `UTType` so that, in the future, other
  platforms can reuse `AttachableImageFormat` instead of implementing their own
  equivalent solution. (As an example, the experimental Windows support
  mentioned previously allows a developer to specify an image codec's `CLSID`.)

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
  that wraps an instance of `CGImage`, you can pass it directly to Image I/O.

- Including convenience getters for additional image formats in
  `AttachableImageFormat`. The set of formats we provide up-front support for is
  intentionally small and limited to formats that are universally supported by
  the various graphics libraries in use today. If we provided a larger set of
  formats that are supported on Apple's platforms, developers may run into
  difficulties porting their test code to platforms that _don't_ support those
  additional formats. For example, Android's [image encoding API](https://developer.android.com/reference/android/graphics/Bitmap.CompressFormat)
  only supports the PNG, JPEG, and WEBP formats. 

## Acknowledgments

Thanks to Apple's testing teams and to the Testing Workgroup for their support
and advice on this project.
