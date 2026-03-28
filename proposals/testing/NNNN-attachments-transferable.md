# `Transferable` Attachments

* Proposal: [ST-NNNN](NNNN-coretransferable-attachments.md)
* Authors: [Julia Vashchenko](https://github.com/aronskaya), [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: 
* Status: **Draft**
* Bug: 
* Implementation: [swiftlang/swift-testing#1519](https://github.com/swiftlang/swift-testing/pull/1519/)
* Review: [pitch](https://forums.swift.org/t/pitch-transferable-attachments/85104)

## Introduction

[ST-0009](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0009-attachments.md) introduced the `Attachment` type that allows tests authors to "attach" arbitrary data blobs to tests. Providing a default implementation for types that conform to [`Transferable` protocol](https://developer.apple.com/documentation/coretransferable/transferable) expands the number of types that can be used as attachments. 

## Motivation

`Transferable` is a Swift protocol declared in the [`CoreTransferable` framework](https://developer.apple.com/documentation/coretransferable) which is shipped with Apple operating systems. The main purpose of it is to convert values to and from binary data. Additionally, it supports writing values to disk as files and reading files back into values. `Transferable` is designed for Swift and is integrated into SwiftUI, AppIntents, and other public APIs.

[ST-0009](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0009-attachments.md) states: 

> Default implementations are provided for types when they conform to Attachable and either Encodable or NSSecureCoding (or both.)

`Transferable` is similar to `Encodable` and `NSSecureCoding` in a way that it also provides functionality to convert values into data blobs, which makes it a perfect candidate to also have a default implementation in order to simplify the testing logic and move some boilerplate code out of it.

## Proposed solution

We propose introducing a new concrete type that conforms to `AttachableWrapper` that wraps a `Transferable` value, and a new initializer on `Attachment` that accepts a `Transferable`. 

```swift
import Testing
import CoreTransferrable

@Test func menuNotEmpty() throws {
    let menu = FoodTruck.menu
    if menu.isEmpty {
        let attachment = try await Attachment(exporting: menu, as: .pdf)
        Attachment.record(attachment)
        Issue.record("The food truck's menu was empty")
    }
}

struct Menu: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { menu in try await menu.pdfData() }
    }
}
```

## Detailed design

The new `Attachment` initializer is defined as follows:

```swift
@available(macOS 15.2, iOS 18.2, tvOS 18.2, visionOS 2.2, watchOS 11.2, *)
extension Attachment {
  /// Initialize an instance of this type that encloses the given transferable
  /// value.
  ///
  /// - Parameters:
  ///   - transferableValue: The value that will be attached to the output of
  ///     the test run.
  ///   - contentType: The content type with which to export `transferableValue`.
  ///     If this argument is `nil`, the testing library calls
  ///     [`exportedContentTypes(_:)`](https://developer.apple.com/documentation/coretransferable/transferable/exportedcontenttypes(_:))
  ///     on `transferableValue` and uses the first type the function returns
  ///     that conforms to [`UTType.data`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/data).
  ///   - preferredName: The preferred name of the attachment to use when saving
  ///     it. If `nil`, the testing library attempts to generate a reasonable
  ///     filename for the attached value.
  ///   - sourceLocation: The source location of the call to this initializer.
  ///     This value is used when recording issues associated with the
  ///     attachment.
  ///
  /// - Throws: Any error that occurs while exporting `transferableValue`.
  ///
  /// Use this initializer to create an instance of ``Attachment`` from a value
  /// that conforms to the [`Transferable`](https://developer.apple.com/documentation/coretransferable/transferable)
  /// protocol.
  ///
  ///      let menu = FoodTruck.menu
  ///      let attachment = try await Attachment(exporting: menu, as: .pdf)
  ///      Attachment.record(attachment)
  ///
  /// When you call this initializer and pass it a transferable value, it
  /// calls [`exported(as:)`](https://developer.apple.com/documentation/coretransferable/transferable/exported(as:))
  /// on that value. This operation may take some time, so this initializer
  /// suspends the calling task until it is complete.
  public init<T>(
    exporting transferableValue: T,
    as contentType: UTType? = nil,
    named preferredName: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws where T: Transferable, AttachableValue == _AttachableTransferableWrapper<T>
}
```

`_AttachableTransferableWrapper` is a new implementor of `AttachableWrapper` which wraps a value that conforms to `Transferable`.

### Source compatibility

This proposal is additive and has no impact on existing code.

### Future directions

None.

### Alternatives considered

* Doing nothing: `Transferable` protocol is adopted widely enough for us to know we want to provide the default implementation for it.
* An alternative would have been to put this functionality into `CoreTransferable` instead of `Testing`. Since `CoreTransferable` is a closed-source project, it would mean that this implementation's source would be closed as well. We preferred to make it open-source by amending` Testing`.
* New overload on `Issue.record(_:sourceLocation:)`. Rather than introducing a new initializer on `Attachment`, we considered adding a new overload on `record(_:sourceLocation:)`. This approach was ultimately rejected for the following reasons.
  Converting a `Transferable` value to an attachable value requires going through `exported(as:)`, which is both async and throwing. Consequently, any overload of `record(_:sourceLocation:)` accepting a `Transferable` value would itself need to be async throws, diverging from the synchronous, non-throwing character of the existing `record(_:sourceLocation:)` API family and placing a burden on call sites that do not require this functionality.
  The asynchronous nature of `exported(as:)` is intentional: encoding a value into its binary representation can be a costly, time-consuming operation, and performing it synchronously would risk blocking the calling actor. Similarly, the throwing behavior reflects the reality that this conversion can fail for a variety of reasons, which must be surfaced to the caller. Representative failure cases include:
    * Unsupported content type. The value cannot be encoded into the requested format.
    * Disk I/O failure. When a value is backed by an on-disk file, materializing it as in-memory data involves file system access, which is inherently fallible.

By encapsulating this complexity inside an `Attachment` initializer, the failure and its reason remain local to the site of attachment construction, keeping `record(_:sourceLocation:)` itself simple and uniformly synchronous.
