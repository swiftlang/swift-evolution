# Add support for Encoding and Decoding nested JSON keys

* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting review**

* Prototype implementation: [diff](https://github.com/calda/NestedKeyEncodingStrategy/pull/1/files#diff-8ff2eba96e32f178462fed931f39208bR205) with [tests](https://github.com/calda/NestedKeyEncodingStrategy/blob/master/NestedKeyEncodingStrategyTests/NestedKeyEncodingStrategyTests.swift)
* Swift Evolution Thread: [Pitch: Add support for Encoding and Decoding nested JSON keys](https://forums.swift.org/t/pitch-add-support-for-encoding-and-decoding-nested-json-keys/34039)

## Introduction

Today, decoding JSON using `JSONDecoder` with a synthesized `Codable` implemenation requires that your object graph has a one-to-one mapping to the object graph of the source JSON. This decreases the control that authors have over their `Codable` models, and can require the creation of unnecessary boilerplate objects.

I propose that we add support for Encoding and Decoding nested JSON keys using [dot notation](https://www.w3schools.com/js/js_json_objects.asp).

A previous Swift-evolution thread: [Support nested custom CodingKeys for Codable types](https://forums.swift.org/t/support-nested-custom-codingkeys-for-codable-types/17300)

## Motivation

Application authors typically have little to no control over the structure of the JSON payloads they receive. It is often desirable to rename or reorganize fields of the payload at the time of deocoding.

Here is a theoretical JSON payload representing a Swift Evolution proposal ([SE-0274](https://github.com/apple/swift-evolution/blob/master/proposals/0274-magic-file.md)):

```json
{
    "id": "SE-0274",
    "title": "Concise magic file names",
    "metadata": {
        "review_start_date": "2020-01-08T00:00:00Z",
        "review_end_date": "2020-01-16T00:00:00Z"
    }
}
```

The consumer of this object may desire to hoist fields from the `metadata` object to the root level:

```swift
struct EvolutionProposal: Codable {
    var id: String
    var title: String
    var reviewStartDate: Date
    var reviewEndDate: Date
}
```

Today, this would require writing a [custom encoding and decoding implementation](https://gist.github.com/calda/6a83e09ae8a4ee1c04557cc7dbdb25f6).

## Proposed solution

I propose that we add support for Encoding and Decoding nested JSON keys using [dot notation](https://www.w3schools.com/js/js_json_objects.asp):

```swift
struct EvolutionProposal: Codable {
    var id: String
    var title: String
    var reviewStartDate: Date
    var reviewEndDate: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case reviewStartDate = "metadata.review_start_date"
        case reviewEndDate = "metadata.review_end_date"
    }
}
```

### Prior art

[`NSDictionary.value(forKeyPath:)`](https://developer.apple.com/documentation/objectivec/nsobject/1416468-value) supports retrieving nested values using dot notation.

Many existing model parsing frameworks support dot notation for decoding nested keys. Some examples include:
 - **[Mantle](https://github.com/Mantle/Mantle#mtlmodel)**, _"Model framework for Cocoa and Cocoa Touch"_
 - **[Unbox](https://github.com/JohnSundell/Unbox#key-path-support)**, _"The easy to use Swift JSON decoder"_
 - **[ObjectMapper](https://github.com/tristanhimmelman/ObjectMapper#easy-mapping-of-nested-objects)**, _"Simple JSON Object mapping written in Swift"_

## Detailed design

I propose implementing this behavior by introducing new `JSONDecoder.NestedKeyDecodingStrategy` and `JSONEncoder.NestedKeyEncodingStrategy` options. These options would function similarly to existing encoding and decoding options like [`KeyEncodingStrategy`](https://developer.apple.com/documentation/foundation/jsonencoder/keyencodingstrategy), [`DateEncodingStrategy`](https://developer.apple.com/documentation/foundation/jsonencoder/dateencodingstrategy), [`NonConformingFloatEncodingStrategy`](https://developer.apple.com/documentation/foundation/jsonencoder/nonconformingfloatencodingstrategy), etc.

```
open class JSONDecoder {

    /// The values that determine how a type's coding keys are used to decode nested object paths.
    public enum NestedKeyDecodingStrategy {
        // A nested key decoding strategy that doesn't treat key names as nested object paths during decoding.
        case useDefaultFlatKeys
        // A nested key decoding strategy that uses JSON Dot Notation to treat key names as nested object paths during decoding.
        case useDotNotation
        // A nested key decoding strategy that uses a custom mapping to treat key names as nested object paths during decoding.
        case custom((CodingKey) -> [CodingKey])
    }
    
    /// The strategy to use for encoding nested keys. Defaults to `.useDefaultFlatKeys`.
    open var nestedKeyEncodingStrategy: NestedKeyEncodingStrategy = .useDefaultFlatKeys
    
    // ...
    
}
```

`JSONDecoder` will use the `NestedKeyDecodingStrategy` to internally convert the original flat `CodingKey` into a nested `[CodingKey]` path. `JSONDecoder` will follow this path to retrieve the value for the given `CodingKey`.

Using the `useDotNotation` option, keys will be transformed using typical JSON / JavaScript [dot notation](https://www.w3schools.com/js/js_json_objects.asp):
 - `"id"` -> `["id"]` 
 - `"metadata.review_end_date"` -> `["metadata", "review_end_date"]`
 - `"arbitrarily.long.nested.path"` -> `["arbitrarily", "long", "nested", "path"]`

Passing `NestedKeyDecodingStrategy.useDotNotation` to our `JSONDecoder` instance allows the examples outlined above to be decoded using their compiler-synthesized codable implementation:

```swift
let decoder = JSONDecoder()
decoder.nestedKeyDecodingStrategy = .useDotNotation
decoder.dateDecodingStrategy = .iso8601
try decoder.decode(EvolutionProposal.self, from: Data(originalJsonPayload.utf8)) // ✅
```

The same public API described for `JSONDecoder.NestedKeyDecodingStrategy` would be used for `JSONEncoder.NestedKeyEncodingStrategy`.

## Source compatibility

This proposal is purely additive, so it has no effect on source compatibility.

## Effect on ABI stability

This proposal is purely additive, so it has no effect on ABI stability.

## Effect on API resilience

This proposal is purely additive to the public API of `Foundation.JSONEncoder` and `Foundation.JSONDecoder`. If this proposal was adopted and implemented, it would not be able to be removed resiliently.

## Alternatives considered

### Make this the default behavior

Valid JSON keys may contain dots:

```
{
    "id": "SE-0274",
    "title": "Concise magic file names",
    "metadata.review_start_date": "2020-01-08T00:00:00Z",
    "metadata.review_end_date": "2020-01-16T00:00:00Z"
}
```

It's very likely that there are existing `Codable` models that rely on this behavior, so we must continue supporting it by default.

We could potentially make `NestedKeyDecodingStrategy.useDotNotation` the default behavior of `JSONDecoder` by preferring the flat key when present. This (probably) wouldn't break any existing models.

We wouldn't be able to support both nested and flat keys in `JSONEncoder`, since encoding is a one-to-one mapping (unlike decoding, which can potentially be a many-to-one mapping).

### Support indexing into arrays or other advanced operations

This design could potentially support advanced operations like indexing into arrays (`metadata.authors[0].email`, etc). Objective-C Key-Value Coding paths, for example, has a [very complex and sophisticated](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueCoding/CollectionOperators.html#//apple_ref/doc/uid/20002176-BAJEAIEE) DSL. The author believes that there isn't enough need or existing precident to warrant a more complex design.

