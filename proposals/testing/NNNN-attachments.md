# Attachments

* Proposal: [SWT-NNNN](NNNN-attachments.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Status: **Awaiting review**
* Bug: [swiftlang/swift-testing#714](https://github.com/swiftlang/swift-testing/issues/714)
* Implementation: [swiftlang/swift-testing#796](https://github.com/swiftlang/swift-testing/pull/796)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Test authors frequently need to include out-of-band data with tests that can be
used to diagnose issues when a test fails. This proposal introduces a new API
called "attachments" (analogous to the same-named feature in XCTest) as well as
the infrastructure necessary to create new attachments and handle them in tools
like VS Code.

## Motivation

When a test fails, especially in a remote environment like CI, it can often be
difficult to determine what exactly has gone wrong. Data that was produced
during the test can be useful, but there is currently no mechanism in Swift
Testing to output arbitrary data other than via `stdout`/`stderr` or via an
artificially-generated issue. A dedicated interface for attaching arbitrary
information to a test would allow test authors to gather relevant information
from a test in a structured way.

## Proposed solution

We propose introducing a new type to Swift Testing, `Attachment`, that represents
some arbitrary "attachment" to associate with a test. Along with `Attachment`,
we will introduce a new protocol, `Attachable`, to which types can conform to
indicate they can be attached to a test.

Default conformances to `Attachable` will be provided for standard library types
that can reasonably be attached. We will also introduce a **cross-import overlay**
with Foundation—that is, a tertiary module that is automatically imported when
a test target imports both Foundation _and_ Swift Testing—that includes
additional conformances for Foundation types such as `Data` and `URL` and
provides support for attaching values that also conform to `Encodable` or
`NSSecureCoding`.

## Detailed design

The `Attachment` type is defined as follows:

```swift
/// A type describing values that can be attached to the output of a test run
/// and inspected later by the user.
///
/// Attachments are included in test reports in Xcode or written to disk when
/// tests are run at the command line. To create an attachment, you need a value
/// of some type that conforms to ``Attachable``. Initialize an instance of
/// ``Attachment`` with that value and, optionally, a preferred filename to use
/// when writing to disk.
public struct Attachment<AttachableValue>: ~Copyable where AttachableValue: Attachable & ~Copyable {
  /// A filename to use when writing this attachment to a test report or to a
  /// file on disk.
  ///
  /// The value of this property is used as a hint to the testing library. The
  /// testing library may substitute a different filename as needed. If the
  /// value of this property has not been explicitly set, the testing library
  /// will attempt to generate its own value.
  public var preferredName: String { get }

  /// The value of this attachment.
  public var attachableValue: AttachableValue { get }

  /// Initialize an instance of this type that encloses the given attachable
  /// value.
  ///
  /// - Parameters:
  ///   - attachableValue: The value that will be attached to the output of the
  ///     test run.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk. If `nil`, the testing library attempts to
  ///     derive a reasonable filename for the attached value.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  public init(
    _ attachableValue: consuming AttachableValue,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  )

  /// Attach this instance to the current test.
  ///
  /// - Parameters:
  ///   - sourceLocation: The source location of the call to this function.
  ///
  /// When attaching a value of a type that does not conform to both
  /// [`Sendable`](https://developer.apple.com/documentation/swift/sendable) and
  /// [`Copyable`](https://developer.apple.com/documentation/swift/copyable),
  /// the testing library encodes it as data immediately. If the value cannot be
  /// encoded and an error is thrown, that error is recorded as an issue in the
  /// current test and the attachment is not written to the test report or to
  /// disk.
  ///
  /// An attachment can only be attached once.
  public consuming func attach(sourceLocation: SourceLocation = #_sourceLocation)

  /// Call a function and pass a buffer representing the value of this
  /// instance's ``attachableValue-2tnj5`` property to it.
  ///
  /// - Parameters:
  ///   - body: A function to call. A temporary buffer containing a data
  ///     representation of this instance is passed to it.
  ///
  /// - Returns: Whatever is returned by `body`.
  ///
  /// - Throws: Whatever is thrown by `body`, or any error that prevented the
  ///   creation of the buffer.
  ///
  /// The testing library uses this function when writing an attachment to a
  /// test report or to a file on disk. This function calls the
  /// ``Attachable/withUnsafeBytes(for:_:)`` function on this attachment's
  /// ``attachableValue-2tnj5`` property.
  @inlinable public borrowing func withUnsafeBytes<R>(
    _ body: (UnsafeRawBufferPointer) throws -> R
  ) throws -> R
}

extension Attachment: Copyable where AttachableValue: Copyable {}
extension Attachment: Sendable where AttachableValue: Sendable {}
```

With `Attachment` comes `Attachable`, a protocol to which "attachable values"
conform:

```swift
/// A protocol describing a type that can be attached to a test report or
/// written to disk when a test is run.
///
/// To attach an attachable value to a test report or test run output, use it to
/// initialize a new instance of ``Attachment``, then call
/// ``Attachment/attach(sourceLocation:)``. An attachment can only be attached
/// once.
///
/// The testing library provides default conformances to this protocol for a
/// variety of standard library types. Most user-defined types do not need to
/// conform to this protocol.
///
/// A type should conform to this protocol if it can be represented as a
/// sequence of bytes that would be diagnostically useful if a test fails. If a
/// type cannot conform directly to this protocol (such as a non-final class or
/// a type declared in a third-party module), you can create a container type
/// that conforms to ``AttachableContainer`` to act as a proxy.
public protocol Attachable: ~Copyable {
  /// An estimate of the number of bytes of memory needed to store this value as
  /// an attachment.
  ///
  /// The testing library uses this property to determine if an attachment
  /// should be held in memory or should be immediately persisted to storage.
  /// Larger attachments are more likely to be persisted, but the algorithm the
  /// testing library uses is an implementation detail and is subject to change.
  ///
  /// The value of this property is approximately equal to the number of bytes
  /// that will actually be needed, or `nil` if the value cannot be computed
  /// efficiently. The default implementation of this property returns `nil`.
  ///
  /// - Complexity: O(1) unless `Self` conforms to `Collection`, in which case
  ///   up to O(_n_) where _n_ is the length of the collection.
  var estimatedAttachmentByteCount: Int? { get }

  /// Call a function and pass a buffer representing this instance to it.
  ///
  /// - Parameters:
  ///   - attachment: The attachment that is requesting a buffer (that is, the
  ///     attachment containing this instance.)
  ///   - body: A function to call. A temporary buffer containing a data
  ///     representation of this instance is passed to it.
  ///
  /// - Returns: Whatever is returned by `body`.
  ///
  /// - Throws: Whatever is thrown by `body`, or any error that prevented the
  ///   creation of the buffer.
  ///
  /// The testing library uses this function when writing an attachment to a
  /// test report or to a file on disk. The format of the buffer is
  /// implementation-defined, but should be "idiomatic" for this type: for
  /// example, if this type represents an image, it would be appropriate for
  /// the buffer to contain an image in PNG format, JPEG format, etc., but it
  /// would not be idiomatic for the buffer to contain a textual description of
  /// the image.
  borrowing func withUnsafeBytes<R>(for attachment: borrowing Attachment<Self>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R

  /// Generate a preferred name for the given attachment.
  ///
  /// - Parameters:
  ///   - attachment: The attachment that needs to be named.
  ///   - suggestedName: A suggested name to use as the basis of the preferred
  ///     name. This string was provided by the developer when they initialized
  ///     `attachment`.
  ///
  /// - Returns: The preferred name for `attachment`.
  ///
  /// The testing library uses this function to determine the best name to use
  /// when adding `attachment` to a test report or persisting it to storage. The
  /// default implementation of this function returns `suggestedName` without
  /// any changes.
  borrowing func preferredName(for attachment: borrowing Attachment<Self>, basedOn suggestedName: String) -> String
}
```

Default conformances to `Attachable` are provided for:

- `Array<UInt8>`, `ContiguousArray<UInt8>`, and `ArraySlice<UInt8>`
- `String` and `Substring`
- `Data` (if Foundation is also imported)

Default _implementations_ are provided for types when they conform to
`Attachable` and either `Encodable` or `NSSecureCoding` (or both.) To use these
conformances, Foundation must be imported because `JSONEncoder` and
`PropertyListEncoder` are members of Foundation, not the Swift standard library.

Some types cannot conform directly to `Attachable` because they require
additional information to encode correctly, or because they are not directly
`Sendable` or `Copyable`. A second protocol, `AttachableContainer`, is provided
that refines `Attachable`:

```swift
/// A protocol describing a type that can be attached to a test report or
/// written to disk when a test is run and which contains another value that it
/// stands in for.
///
/// To attach an attachable value to a test report or test run output, use it to
/// initialize a new instance of ``Attachment``, then call
/// ``Attachment/attach(sourceLocation:)``. An attachment can only be attached
/// once.
///
/// A type can conform to this protocol if it represents another type that
/// cannot directly conform to ``Attachable``, such as a non-final class or a
/// type declared in a third-party module.
public protocol AttachableContainer<AttachableValue>: Attachable, ~Copyable {
  /// The type of the attachable value represented by this type.
  associatedtype AttachableValue

  /// The attachable value represented by this instance.
  var attachableValue: AttachableValue { get }
}

extension Attachment where AttachableValue: AttachableContainer & ~Copyable {
  /// The value of this attachment.
  ///
  /// When the attachable value's type conforms to ``AttachableContainer``, the
  /// value of this property equals the container's underlying attachable value.
  /// To access the attachable value as an instance of `T` (where `T` conforms
  /// to ``AttachableContainer``), specify the type explicitly:
  ///
  /// ```swift
  /// let attachableValue = attachment.attachableValue as T
  /// ```
  public var attachableValue: AttachableValue.AttachableValue { get }
}
```

The cross-import overlay with Foundation also provides the following convenience
interface for attaching the contents of a file or directory on disk:

```swift
extension Attachment where AttachableValue == _AttachableURLContainer {
  /// Initialize an instance of this type with the contents of the given URL.
  ///
  /// - Parameters:
  ///   - url: The URL containing the attachment's data.
  ///   - preferredName: The preferred name of the attachment when writing it to
  ///     a test report or to disk. If `nil`, the name of the attachment is
  ///     derived from the last path component of `url`.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// - Throws: Any error that occurs attempting to read from `url`.
  public init(
    contentsOf url: URL,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws
}
```

`_AttachableURLContainer` is a type that conforms to `AttachableContainer` and
encloses the URL and corresponding mapped data. As an implementation detail, it
is omitted from this proposal for brevity.

## Source compatibility

This proposal is additive and has no impact on existing code.

## Integration with supporting tools

We will add a new command-line argument to the `swift test` command in Swift
Package Manager:

```sh
--attachments-path Path where attachments should be saved.
```

If specified, an attachment will be written to that path when its `attach()`
method is called. If not specified, attachments are not saved to disk. Tools
that indirectly use Swift Testing through `swift test` can specify a path (e.g.
to a directory created inside the system's temporary directory), then move or
delete the created files as needed.

The JSON event stream ABI will be amended correspondingly:

```diff
--- a/Documentation/ABI/JSON.md
+++ b/Documentation/ABI/JSON.md
 <event> ::= {
   "kind": <event-kind>,
   "instant": <instant>, ; when the event occurred
   ["issue": <issue>,] ; the recorded issue (if "kind" is "issueRecorded")
+  ["attachment": <attachment>,] ; the attachment (if kind is "valueAttached")
   "messages": <array:message>,
   ["testID": <test-id>,]
 }

 <event-kind> ::= "runStarted" | "testStarted" | "testCaseStarted" |
   "issueRecorded" | "testCaseEnded" | "testEnded" | "testSkipped" |
-  "runEnded" ; additional event kinds may be added in the future
+  "runEnded" | "valueAttached"; additional event kinds may be added in the future

+<attachment> ::= {
+  "path": <string>, ; the absolute path to the attachment on disk
+}
```

As these changes are additive only, the JSON schema version does not need to be
incremented to support them. We are separately planning to increment the JSON
schema version to support other features; these changes will apply to the newer
version too.

## Future directions

- Attachment lifetime management: XCTest's attachments allow for specifying a
  "lifetime", with two lifetimes currently available:

  ```objc
  typedef NS_ENUM(NSInteger, XCTAttachmentLifetime) {
    XCTAttachmentLifetimeKeepAlways = 0,
    XCTAttachmentLifetimeDeleteOnSuccess = 1
  };
  ```

  If a test passes, it is probably not necessary to keep its attachments saved
  to disk. The exact "shape" this feature should take in Swift Testing is not
  yet clear.

- Image attachments: it is often useful to be able to attach images to tests,
  however there is no cross-platform solution for this functionality. An
  experimental implementation that allows attaching an instance of `CGImage` (on
  Apple platforms) is available in Swift Testing's repository and shows what it
  might look like for us to provide this functionality.

- Additional conformances for types in other modules: in order to keep Swift
  Testing's dependency graph as small as possible, we cannot link it to
  arbitrary packages such as (for example) swift-collections even if it would be
  useful to do so. That means we can't directly provide conformances to
  `Attachable` for types in those modules. Adding additional cross-import
  overlays would allow us to provide those conformances when both Swift Testing
  and those packages are imported at the same time.

  This functionality may require changes in Swift Package Manager that are
  beyond the scope of this proposal.

- Adopting `RawSpan` instead of `UnsafeRawBufferPointer`: `RawSpan` represents a
  safer alternative to `UnsafeRawBufferPointer`, but it is not yet available
  everywhere we'd need it in the standard library, and our minimum deployment
  targets on Apple's platforms do not allow us to require the use of `RawSpan`
  (as no shipping version of Apple's platforms includes it.)

- Adding an associated `Metadata` type to `Attachable` allowing for inclusion of
  arbitrary out-of-band data to attachments: we see several uses for such a
  feature:

  - Fine-grained control of the serialization format used for `Encodable` types;
  - Metrics (scaling factor, rotation, etc.) for images; and
  - Compression algorithms to use for attached files and directories.

  The exact shape of this interface needs further consideration, but it could be
  added in the future without disrupting the interface we are proposing here.
  [swiftlang/swift-testing#824](https://github.com/swiftlang/swift-testing/pull/824)
  includes an experimental implementation of this feature.

## Alternatives considered

- Doing nothing: there's sufficient demand for this feature that we know we want
  to address it.

- Reusing the existing `XCTAttachment` API from XCTest: while this would
  _probably_ have saved me a lot of typing, `XCTAttachment` is an Objective-C
  class and is only available on Apple's platforms. The open-source
  swift-corelibs-xctest package does not include it or an equivalent interface.
  As well, this would create a dependency on XCTest in Swift Testing that does
  not currently exist.

- Implementing `Attachment` as a non-generic type and eagerly serializing
  non-sendable or move-only attachable values: an earlier implementation did
  exactly this, but it forced us to include an existential box in `Attachment`
  to store the attachable value, and that would preclude ever supporting
  attachments in Embedded Swift.

- Having `Attachment` take a byte buffer rather than an attachable value, or
  having it take a closure that returns a byte buffer: this would just raise the
  problem of attaching arbitrary values up to the test author's layer, and that
  would no doubt produce a lot of duplicate implementations of "turn this value
  into a byte buffer" while also worsening the interface's ergonomics.

- Adding a `var contentType: UTType { get set }` property to `Attachment` or to
  `Attachable`: `XCTAttachment` lets you specify a Uniform Type Identifier that
  tells Xcode the type of data. Uniform Type Identifiers are proprietary and not
  available on Linux or Windows, and adding that property would force us to also
  add a public dependency on the `UniformTypeIdentifiers` framework and,
  indirectly, on Foundation, which would prevent Foundation from authoring tests
  using Swift Testing in the future due to the resulting circular dependency.

  We considered using a MIME type instead, but there is no portable mechanism
  for turning a MIME type into a path extension, which is ultimately what we
  need when writing an attachment to persistent storage.

  Instead, `Attachable` includes the function `preferredName(for:basedOn:)` that
  allows an implementation (such as that of `Encodable & Attachable`) to add a
  path extension to the filename specified by the test author if needed.

## Acknowledgments

Thanks to Stuart Montgomery and Brian Croom for goading me into finally writing
this proposal!

Thanks to Wil Addario-Turner for his feedback, in particular around `UTType` and
MIME type support.

Thanks to Honza Dvorsky for his earlier work on attachments in XCTest and his
ideas on how to improve Swift Testing's implementation.
