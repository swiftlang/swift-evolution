# Attachments in the Swift Testing JSON event stream

* Proposal: [ST-NNNN](NNNN-attachments-in-swift-testing-json.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#1845](https://github.com/swiftlang/swift-testing/pull/1845)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Swift Testing exposes a JSON-based event stream API for use by tools and
infrastructure components. This proposal amends the event stream's schema to
include attachment data rather than just filenames.

## Motivation

Filenames for attachments are only useful if the producer and consumer both have
access to the same file system and the consumer is able to read files the
producer writes. These aren't invariants: a consumer may be located on a host
while the producer is on an embedded device; they may be communicating across a
network connection; or the producer may have run much earlier in time while the
consumer is reading a transcript of its event stream at a later date.

The actual bytes contained in an attachment are, universally, the part that is
interesting to an event stream consumer, so we should strive to include those
bytes in said event stream.

## Proposed solution

I propose amending the JSON produced by Swift Testing and compatible tools to
include the bytes of an attachment, and to include the attachment's
`preferredName` property so that the event stream consumer can reliably recreate
the original attachment and save it with a sensible filename as needed.

## Detailed design

The JSON schema is amended as follows as of the `"6.5"` schema version:

- The following rules are defined:

  ```diff
  +<byte> ::= 0 .. 255 ; an 8-bit unsigned byte in standard base 10 notation
  +<bytes> ::= <array:byte> | <base64-string> ; either an array of bytes, or a
  +  ; Base64-encoded representation of an octet stream
  +<base64-string> ::= <string> ; using the standard alphabet, as per RFC 4648
  ```

  These rules describe a sequence of bytes encoded in JSON; more on the optional
  use of Base64 in a moment.

-  The `"path""` field in the `<attachment>` rule becomes optional:

  ```diff
   <attachment> ::= {
  -  "path": <string>, ; the absolute path to the attachment on disk
  +  ["path": <string>,] ; the absolute path to the attachment on disk
  ```

  This field will not be emitted in the event stream if an attachment has never
  been saved to a file. (This is actually already the case in the existing Swift
  Testing implementation, so this change is correcting an existing erratum.)

- The following new fields are added to the `<attachment>` rule:

  ```diff
  +  ["bytes": <bytes>,] ; the serialized form of the attachment
  +  ["error": <error>,] ; an error previously encountered when trying to save the
  +                      ; attachment
  +  ["preferredName": <string>,] ; the preferred name of the attachment when
  +                               ; saving it to disk
   }
  ```

  The `"bytes"` field describes the bytes of the attachment (unsurprisingly).
  The `"error"` field describes any error that was encountered when trying to
  read `"bytes"` during serialization (that is, the error thrown from
  `Attachable.withUnsafeBytes(for:_:)`). And `"preferredName"` equals the
  property of the same name on `Attachment`.

  `"bytes"` and `"error"` are mutually exclusive: if we can read the serialized
  form of an attachment, no error was thrown. If both are present in the JSON,
  a consumer should prefer `"bytes"`.

  `"bytes"` can be represented as either an array of 8-bit unsigned integers or
  as Base64-encoded data using the standard alphabet. Base64 is preferred
  because it requires less storage space, but both are supported because not all
  implementations may be able to support Base64 encoding. Consider for example a
  very small embedded system that can stream arbitrary amounts of data out via a
  serial port, but which has limited storage space for firmware.

  > [!NOTE]
  > Both `"bytes"` and `"path"` are optional. An event stream producer (Swift
  > Testing or otherwise) is not required to provide `"path"`` if there is no
  > valid file system path to the attachment's bytes, nor is it required to
  > provide `"bytes"` if the consumer is able to read the attachment's bytes
  > via another implementation-defined mechanism. However, if the event stream
  > producer provides neither field, the consumer will likely be unable to save
  > its attachments.
  >
  > Swift Testing's `ABI.Record` SPI will accept an encoded attachment with
  > neither field defined, but if you create an instance of `Attachment` from
  > such a value, then call `Attachment.withUnsafeBytes {}` or a function
  > derived from it, Swift Testing will throw an error indicating that the bytes
  > were unavailable.

## Source compatibility

These changes do not affect Swift Testing's API surface.

## Integration with supporting tools

Tools that directly decode Swift Testing's JSON event stream and support the
`"6.5"` schema version onwards will need to be able to decode these additional
fields, and will need to accept `"path"` being `nil`.

Tools using the `ABI.Record` SPI type in Swift Testing will gain this support
automatically.

For some tools, the direct encoding of an attachment's bytes is redundant
because they know they have access to the same file system. For those tools,
they can specify the environment variable
`"SWIFT_TESTING_EVENT_STREAM_ATTACHMENT_BYTES_FIELD_ENABLED"` to skip encoding
the `"bytes"` field entirely.

## Future directions

- **Supporting compression formats for `"bytes"`.** The schema as described does
  not support additional compression of the data. This is an area of interest
  for us, especially for large attachments, but defining a set of mandatory or
  optional compression formats that a producer _may_ use and a consumer _must_
  support is non-trivial.

- **Streaming serialized forms of attachments.** In some cases, where the event
  stream producer and consumer are running concurrently and can establish an
  out-of-band communications channel, it may make sense to allow _streaming_ the
  serialized form of an attachment from producer to consumer instead of encoding
  it directly in in the JSON. This could then reduce transient memory usage. It
  would probably require changes to `Attachable` and `Attachment` to add a
  protocol requirement of the (approximate) form:

  ```swift
  func stream(for attachment: Attachment<Self>, to stream: some Stream) throws
  ```

  The Swift standard library does not define a `Stream` protocol or similar that
  would be suitable here, and such functionality does not belong solely in the
  testing library.

## Alternatives considered

- **Doing nothing.** This limits the ability of a consumer to replay an event
  stream from a producer in another process, on another device, or separated in
  time. We are actively working on support for Embedded Swift and on a "harness"
  process that can abstract away the location and time of a test run, and
  neither would be able to produce saveable attachments without functionality of
  this form.

- **Requiring consumers and producers to share a file system.** This would
  simplify the story: a consumer can always read a file saved by the producer.
  But it's simply not practical: we know we have real-world use cases for Swift
  Testing and for attachments where the consumer isn't located on the same
  physical device or at the same time as the producer.
