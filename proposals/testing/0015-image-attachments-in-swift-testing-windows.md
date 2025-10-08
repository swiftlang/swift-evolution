# Image attachments in Swift Testing (Windows)

* Proposal: [ST-0015](0015-image-attachments-in-swift-testing-windows.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Stuart Montgomery](https://github.com/stmontgomery)
* Status: **Accepted**
* Implementation: [swiftlang/swift-testing#1245](https://github.com/swiftlang/swift-testing/pull/1245), [swiftlang/swift-testing#1254](https://github.com/swiftlang/swift-testing/pull/1254), _et al_.
* Review: ([pitch](https://forums.swift.org/t/pitch-image-attachments-in-swift-testing-windows/81871)) ([review](https://forums.swift.org/t/st-0015-image-attachments-in-swift-testing-windows/82241)) ([acceptance](https://forums.swift.org/t/accepted-st-0015-image-attachments-in-swift-testing-windows/82575))

## Introduction

In [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md),
we added to Swift Testing the ability to attach images (of types `CGImage`,
`NSImage`, `UIImage`, and `CIImage`) on Apple platforms. This proposal builds on
that one to add support for attaching images on Windows.

## Motivation

It is frequently useful to be able to attach images to tests for engineers to
review, e.g. if a UI element is not being drawn correctly. If something doesn't
render correctly in a CI environment, for instance, it is very useful to test
authors to be able to download the failed rendering and examine it at-desk.

In [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md#integration-with-supporting-tools),
we introduced the ability to attach images to tests on Apple's platforms. Swift
Testing is a cross-platform testing library, so we should extend this
functionality to other platforms too. This proposal covers Windows in
particular.

## Proposed solution

We propose adding the ability to automatically encode images to standard
graphics formats such as JPEG or PNG using Windows' built-in Windows Image
Component library, similar to how we added support on Apple platforms using Core
Graphics.

## Detailed design

### Some background about Windows' image types

Windows has several generations of API for representing and encoding images. The
earliest Windows API of interest to this proposal is the Graphics Device
Interface (GDI) which dates back to the earliest versions of Windows. Image
types in GDI that are of interest to us are `HBITMAP` and `HICON`, which are
_handles_ (pointers-to-pointers) and which are not reference-counted. Both types
are projected into Swift as typealiases of `UnsafeMutablePointer`.

Windows' latest[^direct2d] graphics API is the Windows Imaging Component (WIC)
which uses types based on the Component Object Model (COM). COM types (including
those implemented in WIC) are C++ classes that inherit from `IUnknown`.

[^direct2d]: There is an even newer API in this area, Direct2D, but it is beyond
  the scope of this proposal. A developer who has an instance of e.g.
  `ID2D1Bitmap` can use WIC API to convert it to a WIC bitmap source before
  attaching it to a test.

`IUnknown` is conceptually similar to Cocoa's `NSObject` class in that it
provides basic reference-counting and reflection functionality. As of this
proposal, the Swift C/C++ importer is not aware of COM classes and does not
project them into Swift as reference-counted classes. Rather, they are projected
as `UnsafeMutablePointer<T>`, and developers who use them must manually manage
their reference counts and must use `QueryInterface()` to cast them to other COM
classes.

In short: the types we need to support are all specializations of
`UnsafeMutablePointer`, but we do not need to support all specializations of
`UnsafeMutablePointer` unconditionally.

### Defining a new protocol for Windows image attachments

A new protocol is introduced for Windows, similar to the `AttachableAsCGImage`
protocol we introduced for Apple's platforms:

```swift
/// A protocol describing images that can be converted to instances of
/// [`Attachment`](https://developer.apple.com/documentation/testing/attachment).
///
/// Instances of types conforming to this protocol do not themselves conform to
/// [`Attachable`](https://developer.apple.com/documentation/testing/attachable).
/// Instead, the testing library provides additional initializers on [`Attachment`](https://developer.apple.com/documentation/testing/attachment)
/// that take instances of such types and handle converting them to image data when needed.
///
/// You can attach instances of the following system-provided image types to a
/// test:
///
/// | Platform | Supported Types |
/// |-|-|
/// | macOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage) |
/// | iOS, watchOS, tvOS, and visionOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage) |
/// | Windows | [`HBITMAP`](https://learn.microsoft.com/en-us/windows/win32/gdi/bitmaps), [`HICON`](https://learn.microsoft.com/en-us/windows/win32/menurc/icons), [`IWICBitmapSource`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapsource) (including its subclasses declared by Windows Imaging Component) |
///
/// You do not generally need to add your own conformances to this protocol. If
/// you have an image in another format that needs to be attached to a test,
/// first convert it to an instance of one of the types above.
public protocol AttachableAsIWICBitmapSource: SendableMetatype {
  /// Create a WIC bitmap source representing an instance of this type.
  ///
  /// - Returns: A pointer to a new WIC bitmap source representing this image.
  ///   The caller is responsible for releasing this image when done with it.
  ///
  /// - Throws: Any error that prevented the creation of the WIC bitmap source.
  func copyAttachableIWICBitmapSource() throws -> UnsafeMutablePointer<IWICBitmapSource>
}
```

Conformance to this protocol is added to `UnsafeMutablePointer` when its
`Pointee` type is one of the following types:

- [`HBITMAP.Pointee`](https://learn.microsoft.com/en-us/windows/win32/gdi/bitmaps)
- [`HICON.Pointee`](https://learn.microsoft.com/en-us/windows/win32/menurc/icons)
- [`IWICBitmapSource`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapsource)
  (including its subclasses declared by Windows Imaging Component)

> [!NOTE]
> The list of conforming types may be extended in the future. The Testing
> Workgroup will determine if additional Swift Evolution reviews are needed.

A type in Swift can only conform to a protocol with **one** set of constraints,
so we need a helper protocol in order to make `UnsafeMutablePointer`
conditionally conform for all of the above types. This protocol must be `public`
so that Swift Testing can refer to it in API, but it is an implementation detail
and not part of this proposal:

```swift
public protocol _AttachableByAddressAsIWICBitmapSource {}

extension HBITMAP.Pointee: _AttachableByAddressAsIWICBitmapSource {}
extension HICON.Pointee: _AttachableByAddressAsIWICBitmapSource {}
extension IWICBitmapSource: _AttachableByAddressAsIWICBitmapSource {}

extension UnsafeMutablePointer: AttachableAsIWICBitmapSource
  where Pointee: _AttachableByAddressAsIWICBitmapSource {}
```

See the **Future directions** section (specifically the point about COM and C++
interop) for more information on why the helper protocol is excluded from this
proposal.

### Attaching a conforming image

New overloads of `Attachment.init()` and `Attachment.record()` are provided:

```swift
extension Attachment {
  /// Initialize an instance of this type that encloses the given image.
  ///
  /// - Parameters:
  ///   - image: A pointer to the value that will be attached to the output of
  ///     the test run.
  ///   - preferredName: The preferred name of the attachment when writing it
  ///     to a test report or to disk. If `nil`, the testing library attempts
  ///     to derive a reasonable filename for the attached value.
  ///   - imageFormat: The image format with which to encode `image`.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// You can attach instances of the following system-provided image types to a
  /// test:
  ///
  /// | Platform | Supported Types |
  /// |-|-|
  /// | macOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage) |
  /// | iOS, watchOS, tvOS, and visionOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage) |
  /// | Windows | [`HBITMAP`](https://learn.microsoft.com/en-us/windows/win32/gdi/bitmaps), [`HICON`](https://learn.microsoft.com/en-us/windows/win32/menurc/icons), [`IWICBitmapSource`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapsource) (including its subclasses declared by Windows Imaging Component) |
  ///
  /// The testing library uses the image format specified by `imageFormat`. Pass
  /// `nil` to let the testing library decide which image format to use. If you
  /// pass `nil`, then the image format that the testing library uses depends on
  /// the path extension you specify in `preferredName`, if any. If you do not
  /// specify a path extension, or if the path extension you specify doesn't
  /// correspond to an image format the operating system knows how to write, the
  /// testing library selects an appropriate image format for you.
  public init<T>(
    _ image: T,
    named preferredName: String? = nil,
    as imageFormat: AttachableImageFormat? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) where T: AttachableAsIWICBitmapSource, AttachableValue == _AttachableImageWrapper<T>

  /// Attach an image to the current test.
  ///
  /// - Parameters:
  ///   - image: The value to attach.
  ///   - preferredName: The preferred name of the attachment when writing it
  ///     to a test report or to disk. If `nil`, the testing library attempts
  ///     to derive a reasonable filename for the attached value.
  ///   - imageFormat: The image format with which to encode `image`.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// This function creates a new instance of ``Attachment`` wrapping `image`
  /// and immediately attaches it to the current test. You can attach instances
  /// of the following system-provided image types to a test:
  ///
  /// | Platform | Supported Types |
  /// |-|-|
  /// | macOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`NSImage`](https://developer.apple.com/documentation/appkit/nsimage) |
  /// | iOS, watchOS, tvOS, and visionOS | [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage), [`CIImage`](https://developer.apple.com/documentation/coreimage/ciimage), [`UIImage`](https://developer.apple.com/documentation/uikit/uiimage) |
  /// | Windows | [`HBITMAP`](https://learn.microsoft.com/en-us/windows/win32/gdi/bitmaps), [`HICON`](https://learn.microsoft.com/en-us/windows/win32/menurc/icons), [`IWICBitmapSource`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapsource) (including its subclasses declared by Windows Imaging Component) |
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
  ) where T: AttachableAsIWICBitmapSource, AttachableValue == _AttachableImageWrapper<T>
}
```

> [!NOTE]
> `_AttachableImageWrapper` was described in [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md#attaching-a-conforming-image).
> The only difference on Windows is that its associated `Image` type is
> constrained to `AttachableAsIWICBitmapSource` instead of `AttachableAsCGImage`.

### Specifying image formats

As on Apple platforms, a test author can specify the image format to use with
`AttachableImageFormat`. See [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md#specifying-image-formats)
for more information about that type.

Windows does not use Uniform Type Identifiers, so those `AttachableImageFormat`
members that use `UTType` are not available here. Instead, Windows uses a
variety of COM classes that implement codecs for different image formats.
Conveniences over those COM classes' `CLSID` values are provided:

```swift
extension AttachableImageFormat {
  /// The `CLSID` value of the Windows Imaging Component (WIC) encoder class
  /// that corresponds to this image format.
  ///
  /// For example, if this image format equals ``png``, the value of this
  /// property equals [`CLSID_WICPngEncoder`](https://learn.microsoft.com/en-us/windows/win32/wic/-wic-guids-clsids#wic-guids-and-clsids).
  public var encoderCLSID: CLSID { get }

  /// Construct an instance of this type with the `CLSID` value of a Windows
  /// Imaging Component (WIC) encoder class and the desired encoding quality.
  ///
  /// - Parameters:
  ///   - encoderCLSID: The `CLSID` value of the Windows Imaging Component
  ///     encoder class to use when encoding images.
  ///   - encodingQuality: The encoding quality to use when encoding images. For
  ///     the lowest supported quality, pass `0.0`. For the highest supported
  ///     quality, pass `1.0`.
  ///
  /// If the target image encoder does not support variable-quality encoding,
  /// the value of the `encodingQuality` argument is ignored.
  ///
  /// If `clsid` does not represent an image encoder class supported by WIC, the
  /// result is undefined. For a list of image encoder classes supported by WIC,
  /// see the documentation for the [`IWICBitmapEncoder`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapencoder)
  /// class.
  public init(encoderCLSID: CLSID, encodingQuality: Float = 1.0)
}
```

For convenience, an initializer is provided that takes a path extension and
tries to map it to the appropriate codec's `CLSID` value:

```swift
extension AttachableImageFormat {
  /// Construct an instance of this type with the given path extension and
  /// encoding quality.
  ///
  /// - Parameters:
  ///   - pathExtension: A path extension corresponding to the image format to
  ///     use when encoding images.
  ///   - encodingQuality: The encoding quality to use when encoding images. For
  ///     the lowest supported quality, pass `0.0`. For the highest supported
  ///     quality, pass `1.0`.
  ///
  /// If the target image format does not support variable-quality encoding,
  /// the value of the `encodingQuality` argument is ignored.
  ///
  /// If `pathExtension` does not correspond to a recognized image format, this
  /// initializer returns `nil`:
  ///
  /// - On Apple platforms, the content type corresponding to `pathExtension`
  ///   must conform to [`UTType.image`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/image).
  /// - On Windows, there must be a corresponding subclass of [`IWICBitmapEncoder`](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicbitmapencoder)
  ///   registered with Windows Imaging Component.
  public init?(pathExtension: String, encodingQuality: Float = 1.0)
}
```

For consistency, `init(pathExtension:encodingQuality:)` is provided on Apple
platforms too. (This is the only part of this proposal that affects platforms
other than Windows.)

### Example usage

A developer may then easily attach an image to a test by calling
`Attachment.record()` and passing the image of interest. For example, to attach
an icon to a test as a PNG file:

```swift
import Testing
import WinSDK

@MainActor @Test func `attaching an icon`() throws {
  let hIcon: HICON = ...
  defer {
    DestroyIcon(hIcon)
  }
  Attachment.record(hIcon, named: "my icon", as: .png)
  // OR: Attachment.record(hIcon, named: "my icon.png")
}
```

## Source compatibility

This change is additive only.

## Integration with supporting tools

Tools that handle attachments created by Swift Testing will gain support for
this functionality automatically and do not need to make any changes.

## Future directions

- Adding support for projecting COM classes as foreign-reference-counted Swift
  classes. The C++ interop team is interested in implementing this feature, but
  it is beyond the scope of this proposal. **If this feature is implemented in
  the future**, it will cause types like `IWICBitmapSource` to be projected
  directly into Swift instead of as `UnsafeMutablePointer` specializations. This
  would be a source-breaking change for Swift Testing, but it would make COM
  classes much easier to use in Swift.

  In the context of this proposal, `IWICBitmapSource` would be able to directly
  conform to `AttachableAsIWICBitmapSource` and we would no longer need the
  `_AttachableByAddressAsIWICBitmapSource` helper protocol. The
  `AttachableAsIWICBitmapSource` protocol's `copyAttachableIWICBitmapSource()`
  requirement would likely change to a property (i.e.
  `var attachableIWICBitmapSource: IWICBitmapSource { get throws }`) as it would
  be able to participate in Swift's automatic reference counting.

  The Swift team is tracking COM interop with [swiftlang/swift#84056](https://github.com/swiftlang/swift/issues/84056).

- Adding support for managed (.NET or C#) image types. Support for managed types
  on Windows would first require a new Swift/.NET or Swift/C# interop feature
  and is therefore beyond the scope of this proposal.

- Adding support for WinRT image types. WinRT is a thin wrapper around COM and
  has C++ and .NET projections, neither of which are readily accessible from
  Swift. It may be possible to add support for WinRT image types if COM interop
  is implemented.

- Adding support for other platforms. See [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md#future-directions)
  for further discussion about supporting additional platforms.

## Alternatives considered

- Doing nothing. We have already added support for attaching images on Apple's
  platforms, and Swift Testing is meant to be a cross-platform library, so we
  should make a best effort to provide the same functionality on Windows and,
  eventually, other platforms.

- Using more Windows-/COM-like terminology and spelling, e.g.
  `CloneAttachableBitmapSource()` instead of `copyAttachableIWICBitmapSource()`.
  Swift API should follow Swift API guidelines, even when extending types and
  calling functions implemented under other standards.

- Making `IWICBitmapSource` conform directly to `Attachable`. As with `CGImage`
  in [ST-0014](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0014-image-attachments-in-swift-testing-apple-platforms.md#alternatives-considered),
  this would prevent us from including additional information (i.e. an instance
  of `AttachableImageFormat`). Further, it would be difficult to correctly
  manage the lifetime of Windows' 'image objects as they do not participate in
  automatic reference counting.

- Using the GDI+ type [`Gdiplus.Image`](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nl-gdiplusheaders-image)
  as our currency type instead of `IWICBitmapSource`. This type is a C++ class
  but is not a COM class, and so it is not projected into Swift except as
  `OpaquePointer` which makes it unsafe to extend it with protocol conformances.
  As well, GDI+ is a much older API than WIC and is not recommended by Microsoft
  for new development.

- Designing a platform-agnostic solution. This would likely require adding a
  dependency on an open-source image package such as [ImageMagick](https://github.com/ImageMagick/ImageMagick).
  Such a library would be a significant new dependency for the testing library
  and the Swift toolchain at large.

## Acknowledgments

Thank you to @compnerd and the C++ interop team for their help with Windows and
the COM API.
