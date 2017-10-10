# Swift Encoders

* Proposal: [SE-0167](0167-swift-encoders.md)
* Authors: [Itai Ferber](https://github.com/itaiferber), [Michael LeHew](https://github.com/mlehew), [Tony Parker](https://github.com/parkera)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-April/000368.html)
* Implementation: [apple/swift#9005](https://github.com/apple/swift/pull/9005)

## Introduction

As part of the proposal for a Swift archival and serialization API ([SE-0166](0166-swift-archival-serialization.md)), we are also proposing new API for specific new encoders and decoders, as well as introducing support for new `Codable` types in `NSKeyedArchiver` and `NSKeyedUnarchiver`.

This proposal composes the latter two stages laid out in [SE-0166](0166-swift-archival-serialization.md).

## Motivation

With the base API discussed in [SE-0166](0166-swift-archival-serialization.md), we want to provide new encoders for consumers of this API, as well as provide a consistent story for bridging this new API with our existing `NSCoding` implementations. We would like to offer a base level of support that users can depend on, and set a pattern that third parties can follow in implementing and extending their own encoders.

## Proposed solution

We will:

1. Add two new encoders and decoders to support encoding Swift value trees in JSON and property list formats
2. Add support for passing `Codable` Swift values to `NSKeyedArchiver` and `NSKeyedUnarchiver`, and add `Codable` conformance to our Swift value types

## Detailed design

### New Encoders and Decoders

#### JSON

One of the key motivations for the introduction of this API was to allow safer interaction between Swift values and their JSON representations. For values which are `Codable`, users can encode to and decode from JSON with `JSONEncoder` and `JSONDecoder`:

```swift
open class JSONEncoder {
    // MARK: Top-Level Encoding

    /// Encodes the given top-level value and returns its JSON representation.
    ///
    /// - parameter value: The value to encode.
    /// - returns: A new `Data` value containing the encoded JSON data.
    /// - throws: `CocoaError.coderInvalidValue` if a non-comforming floating-point value is encountered during archiving, and the encoding strategy is `.throw`.
    /// - throws: An error if any value throws an error during encoding.
    open func encode<T : Encodable>(_ value: T) throws -> Data

    // MARK: Customization

    /// The formatting of the output JSON data.
    public enum OutputFormatting {
        /// Produce JSON compacted by removing whitespace. This is the default formatting.
        case compact

        /// Produce human-readable JSON with indented output.
        case prettyPrinted
    }

    /// The strategy to use for encoding `Date` values.
    public enum DateEncodingStrategy {
        /// Defer to `Date` for choosing an encoding. This is the default strategy.
        case deferredToDate

        /// Encode the `Date` as a UNIX timestamp (as a JSON number).
        case secondsSince1970

        /// Encode the `Date` as UNIX millisecond timestamp (as a JSON number).
        case millisecondsSince1970

        /// Encode the `Date` as an ISO-8601-formatted string (in RFC 3339 format).
        @available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601

        /// Encode the `Date` as a string formatted by the given formatter.
        case formatted(DateFormatter)

        /// Encode the `Date` as a custom value encoded by the given closure.
        ///
        /// If the closure fails to encode a value into the given encoder, the encoder will encode an empty `.default` container in its place.
        case custom((_ value: Date, _ encoder: Encoder) throws -> Void)
    }

    /// The strategy to use for encoding `Data` values.
    public enum DataEncodingStrategy {
        /// Encoded the `Data` as a Base64-encoded string. This is the default strategy.
        case base64

        /// Encode the `Data` as a custom value encoded by the given closure.
        ///
        /// If the closure fails to encode a value into the given encoder, the encoder will encode an empty `.default` container in its place.
        case custom((_ value: Data, _ encoder: Encoder) throws -> Void)
    }

    /// The strategy to use for non-JSON-conforming floating-point values (IEEE 754 infinity and NaN).
    public enum NonConformingFloatEncodingStrategy {
        /// Throw upon encountering non-conforming values. This is the default strategy.
        case `throw`

        /// Encode the values using the given representation strings.
        case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The output format to produce. Defaults to `.compact`.
    open var outputFormatting: OutputFormatting

    /// The strategy to use in encoding dates. Defaults to `.deferredToDate`.
    open var dateEncodingStrategy: DateEncodingStrategy

    /// The strategy to use in encoding binary data. Defaults to `.base64`.
    open var dataEncodingStrategy: DataEncodingStrategy

    /// The strategy to use in encoding non-conforming numbers. Defaults to `.throw`.
    open var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy

    /// Contextual information to expose during encoding.
    open var userInfo: [CodingUserInfoKey : Any]
}

open class JSONDecoder {
    // MARK: Top-Level Decoding

    /// Decodes a top-level value of the given type from the given JSON representation.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter data: The data to decode from.
    /// - returns: A value of the requested type.
    /// - throws: `CocoaError.coderReadCorrupt` if values requested from the payload are corrupted, or if the given data is not valid JSON.
    /// - throws: An error if any value throws an error during decoding.
    open func decode<T : Decodable>(_ type: T.Type, from data: Data) throws -> Value

    // MARK: Customization

    /// The strategy to use for decoding `Date` values.
    public enum DateDecodingStrategy {
        /// Defer to `Date` for decoding. This is the default strategy.
        case deferredToDate

        /// Decode the `Date` as a UNIX timestamp from a JSON number.
        case secondsSince1970

        /// Decode the `Date` as UNIX millisecond timestamp from a JSON number.
        case millisecondsSince1970

        /// Decode the `Date` as an ISO-8601-formatted string (in RFC 3339 format).
        @available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601

        /// Decode the `Date` as a string parsed by the given formatter.
        case formatted(DateFormatter)

        /// Decode the `Date` as a custom value decoded by the given closure.
        case custom((_ decoder: Decoder) throws -> Date)
    }

    /// The strategy to use for decoding `Data` values.
    public enum DataDecodingStrategy {
        /// Decode the `Data` from a Base64-encoded string. This is the default strategy.
        case base64

        /// Decode the `Data` as a custom value decoded by the given closure.
        case custom((_ decoder: Decoder) throws -> Data)
    }

    /// The strategy to use for non-JSON-conforming floating-point values (IEEE 754 infinity and NaN).
    public enum NonConformingFloatDecodingStrategy {
        /// Throw upon encountering non-conforming values. This is the default strategy.
        case `throw`

        /// Decode the values from the given representation strings.
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy to use in decoding dates. Defaults to `.deferredToDate`.
    open var dateDecodingStrategy: DateDecodingStrategy

    /// The strategy to use in decoding binary data. Defaults to `.base64`.
    open var dataDecodingStrategy: DataDecodingStrategy

    /// The strategy to use in decoding non-conforming numbers. Defaults to `.throw`.
    open var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy

    /// Contextual information to expose during decoding.
    open var userInfo: [CodingUserInfoKey : Any]
}
```

Usage:

```swift
var encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.dataEncodingStrategy = .custom(myBase85Encoder)

// Since JSON does not natively allow for infinite or NaN values, we can customize strategies for encoding these non-conforming values.
encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "INF", negativeInfinity: "-INF", nan: "NaN")

// MyValue conforms to Codable
let topLevel = MyValue(...)

let payload: Data
do {
    payload = try encoder.encode(topLevel)
} catch {
    // Some value threw while encoding.
}

// ...

var decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
decoder.dataDecodingStrategy = .custom(myBase85Decoder)

// Look for and match these values when decoding `Double`s or `Float`s.
decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "INF", negativeInfinity: "-INF", nan: "NaN")

let topLevel: MyValue
do {
    topLevel = try decoder.decode(MyValue.self, from: payload)
} catch {
    // Data was corrupted, or some value threw while decoding.
}
```

It should be noted here that `JSONEncoder` and `JSONDecoder` do not themselves conform to `Encoder` and `Decoder`; instead, they contain private nested types which do conform to `Encoder` and `Decoder`, which are passed to values' `encode(to:)` and `init(from:)`. This is because `JSONEncoder` and `JSONDecoder` must present a different top-level API than they would at intermediate levels.

#### Property List

We also intend to support the property list format, with `PropertyListEncoder` and `PropertyListDecoder`:

```swift
open class PropertyListEncoder {
    // MARK: Top-Level Encoding

    /// Encodes the given top-level value and returns its property list representation.
    ///
    /// - parameter value: The value to encode.
    /// - returns: A new `Data` value containing the encoded property list data.
    /// - throws: An error if any value throws an error during encoding.
    open func encode<T : Encodable>(_ value: T) throws -> Data

    // MARK: Customization

    /// The output format to write the property list data in. Defaults to `.binary`.
    open var outputFormat: PropertyListSerialization.PropertyListFormat

    /// Contextual information to expose during encoding.
    open var userInfo: [CodingUserInfoKey : Any]
}

open class PropertyListDecoder {
    // MARK: Top-Level Decoding

    /// Decodes a top-level value of the given type from the given property list representation.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter data: The data to decode from.
    /// - returns: A value of the requested type.
    /// - throws: `CocoaError.coderReadCorrupt` if values requested from the payload are corrupted, or if the given data is not a valid property list.
    /// - throws: An error if any value throws an error during decoding.
    open func decode<T : Decodable>(_ type: T.Type, from data: Data) throws -> Value

    /// Decodes a top-level value of the given type from the given property list representation.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter data: The data to decode from.
    /// - parameter format: The parsed property list format.
    /// - returns: A value of the requested type along with the detected format of the property list.
    /// - throws: `CocoaError.coderReadCorrupt` if values requested from the payload are corrupted, or if the given data is not a valid property list.
    /// - throws: An error if any value throws an error during decoding.
    open func decode<T : Decodable>(_ type: Value.Type, from data: Data, format: inout PropertyListSerialization.PropertyListFormat) throws -> Value

    // MARK: Customization

    /// Contextual information to expose during decoding.
    open var userInfo: [CodingUserInfoKey : Any]
}
```

Usage:

```swift
let encoder = PropertyListEncoder()
let topLevel = MyValue(...)
let payload: Data
do {
    payload = try encoder.encode(topLevel)
} catch {
    // Some value threw while encoding.
}

// ...

let decoder = PropertyListDecoder()
let topLevel: MyValue
do {
    topLevel = try decoder.decode(MyValue.self, from: payload)
} catch {
    // Data was corrupted, or some value threw while decoding.
}
```

Like with JSON, `PropertyListEncoder` and `PropertyListDecoder` also provide private nested types which conform to `Encoder` and `Decoder` for performing the archival.

### Foundation-Provided Errors

Along with providing the above encoders and decoders, we would like to promote the use of a common set of error codes and messages across all new encoders and decoders. A common vocabulary of expected errors allows end-users to write code agnostic about the specific encoder/decoder implementation they are working with, whether first-party or third-party:

```swift
extension CocoaError.Code {
    /// Thrown when a value incompatible with the output format is encoded.
    public static var coderInvalidValue: CocoaError.Code

    /// Thrown when a value of a given type is requested but the encountered value is of an incompatible type.
    public static var coderTypeMismatch: CocoaError.Code

    /// Thrown when read data is corrupted or otherwise invalid for the format. This value already exists today.
    public static var coderReadCorrupt: CocoaError.Code

    /// Thrown when a requested key or value is unexpectedly null or missing. This value already exists today.
    public static var coderValueNotFound: CocoaError.Code
}

// These reexpose the values above.
extension CocoaError {
    public static var coderInvalidValue: CocoaError.Code

    public static var coderTypeMismatch: CocoaError.Code
}
```

The localized description strings associated with the two new error codes are:

* `.coderInvalidValue`: "The data is not valid for encoding in this format."
* `.coderTypeMismatch`: "The data couldn't be read because it isn't in the correct format." (Precedent from `NSCoderReadCorruptError`.)

All of these errors will include the coding key path that led to the failure in the error's `userInfo` dictionary under `NSCodingPathErrorKey`, along with a non-localized, developer-facing failure reason under `NSDebugDescriptionErrorKey`.

### `NSKeyedArchiver` & `NSKeyedUnarchiver` Changes

Although our primary objectives for this new API revolve around Swift, we would like to make it easy for current consumers to make the transition to `Codable` where appropriate. As part of this, we would like to bridge compatibility between new `Codable` types (or newly-`Codable`-adopting types) and existing `NSCoding` types.

To do this, we want to introduce changes to `NSKeyedArchiver` and `NSKeyedUnarchiver` in Swift that allow archival of `Codable` types intermixed with `NSCoding` types:

```swift
// These are provided in the Swift overlay, and included in swift-corelibs-foundation.
extension NSKeyedArchiver {
    public func encodeCodable(_ codable: Encodable?, forKey key: String) { ... }
}

extension NSKeyedUnarchiver {
    public func decodeCodable<T : Decodable>(_ type: T.Type, forKey key: String) -> T? { ... }
}
```

> NOTE: Since these changes are being made in extensions in the Swift overlay, it is not yet possible for these methods to be overridden. These can therefore not be added to `NSCoder`, since `NSKeyedArchiver` and `NSKeyedUnarchiver` would not be able to provide concrete implementations. In order to call these methods, it is necessary to downcast from an `NSCoder` to `NSKeyedArchiver`/`NSKeyedUnarchiver` directly. Since subclasses of `NSKeyedArchiver` and `NSKeyedUnarchiver` in Swift will inherit these implementations without being able to override them (which is wrong), we will `NSRequiresConcreteImplementation()` dynamically in subclasses.

The addition of these methods allows the introduction of `Codable` types into existing `NSCoding` structures, allowing for a transition to `Codable` types where appropriate.

#### Refining `encode(_:forKey:)`

Along with these extensions, we would like to refine the import of `-[NSCoder encodeObject:forKey:]`, which is currently imported into Swift as `encode(_: Any?, forKey: String)`. This method currently accepts Objective-C and Swift objects conforming to `NSCoding` (non-conforming objects produce a runtime error), as well as bridgeable Swift types (`Data`, `String`, `Array`, etc.); we would like to extend it to support new Swift `Codable` types, which would otherwise produce a runtime error upon call.

`-[NSCoder encodeObject:forKey:]` will be given a new Swift name of `encodeObject(_:forKey:)`, and we will provide a replacement `encode(_: Any?, forKey: String)` in the overlay which will funnel out to either `encodeCodable(_:forKey:)` or `encodeObject(_:forKey:)` as appropriate. This should maintain source compatibility for end users already calling `encode(_:forKey:)`, as well as behavior compatibility for subclassers of `NSCoder` and `NSKeyedArchiver` who may be providing their own `encode(_:forKey:)`.

#### Semantics of `Codable` Types in Archives

There are a few things to note about including `Codable` values in `NSKeyedArchiver` archives:

* Bridgeable Foundation types will always bridge before encoding. This is to facilitate writing Foundation types in a compatible format from both Objective-C and Swift
    * On decode, these types will decode either as their Objective-C or Swift version, depending on user need (`decodeObject(forKey:)` will decode as an Objective-C object; `decodeCodable(_:forKey:)` as a Swift value)
* User types, which are not bridgeable, do not write out a `$class` and can only be decoded in Swift. In the future, we may add API to allow Swift types to provide an Objective-C class to decode as, effectively allowing for user bridging across archival

##### Foundation Types Adopting `Codable`

The following Foundation Swift types will be adopting `Codable`, and will encode as their bridged types when encoded through `NSKeyedArchiver`, as mentioned above:

* `AffineTransform`
* `Calendar`
* `CharacterSet`
* `Date`
* `DateComponents`
* `DateInterval`
* `Decimal`
* `IndexPath`
* `IndexSet`
* `Locale`
* `Measurement`
* `Notification`
* `PersonNameComponents`
* `TimeZone`
* `URL`
* `URLComponents`
* `URLRequest`
* `UUID`

Along with these, the `Array`, `Dictionary`, and `Set` types will gain `Codable` conformance (as part of the Conditional Conformance feature), and encode through `NSKeyedArchiver` as `NSArray`, `NSDictionary`, and `NSSet` respectively.

## Source compatibility

The majority of this proposal is additive. The changes to `NSKeyedArchiver` are intended to be non-source-breaking changes, and non-behavior-breaking changes for subclasses in Objective-C and Swift.

## Effect on ABI stability

The addition of this API will not be an ABI-breaking change. However, this will add limitations for changes in future versions of Swift, as parts of the API will have to remain unchanged between versions of Swift (barring some additions, discussed below).

## Effect on API resilience

Much like new API added to the standard library, once added, some changes to this API will be ABI- and source-breaking changes. Changes to the new encoder and decoder classes provided above will be restricted as described in the [library evolution document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst) in the Swift repository; in particular, the removal of methods or nested types or changes to argument types will break client behavior. Additionally, additions to provided options `enum`s will be a source-breaking change for users performing an exhaustive switch over their cases; removal of cases will be ABI-breaking.

