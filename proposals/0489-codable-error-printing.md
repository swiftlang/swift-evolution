# Improve `EncodingError` and `DecodingError`'s printed descriptions

* Proposal: [SE-0489](0489-codable-error-printing.md)
* Authors: [Zev Eisenberg](https://github.com/ZevEisenberg)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Accepted**
* Implementation: https://github.com/swiftlang/swift/pull/80941
* Review: ([pitch](https://forums.swift.org/t/pitch-improve-encodingerror-and-decodingerror-s-printed-descriptions/79872)) ([review](https://forums.swift.org/t/se-0489-improve-encodingerror-and-decodingerrors-printed-descriptions/81021)) ([acceptance](https://forums.swift.org/t/accepted-se-0489-improve-encodingerror-and-decodingerrors-printed-descriptions/81380))

## Introduction

`EncodingError` and `DecodingError` do not specify any custom debug description. The default descriptions bury the useful information in a format that is difficult to read. Less experienced developers may assume they are not human-readable at all, even though they contain useful information. The proposal is to conform `EncodingError` and `DecodingError` to `CustomDebugStringConvertible` and provide nicely formatted debug output.

## Motivation

Consider the following example model structs:

```swift
struct Person: Codable {
  var name: String
  var home: Home
}

struct Home: Codable {
  var city: String
  var country: Country
}

struct Country: Codable {
  var name: String
  var population: Int
}
```

Now let us attempt to decode some invalid JSON. In this case, it is missing a field in a deeply nested struct.

```swift
// Note missing "population" field
let jsonData = Data("""
[
  {
    "name": "Ada Lovelace",
    "home": {
      "city": "London",
      "country": {
        "name": "England"
      }
    }
  }
]
""".utf8)

do {
  _ = try JSONDecoder().decode([Person].self, from: jsonData)
} catch {
  print(error)
}
```

This outputs the following:

`keyNotFound(CodingKeys(stringValue: "population", intValue: nil), Swift.DecodingError.Context(codingPath: [_CodingKey(stringValue: "Index 0", intValue: 0), CodingKeys(stringValue: "home", intValue: nil), CodingKeys(stringValue: "country", intValue: nil)], debugDescription: "No value associated with key CodingKeys(stringValue: \"population\", intValue: nil) (\"population\").", underlyingError: nil))`

All the information you need is there:
- The kind of error: a missing key
- Which key was missing: `"population"`
- The path of the value that had a missing key: index 0, then key `"home"`, then key `"country"`
- The underlying error: none, in this case

However, it is not easy or pleasant to read such an error, particularly when dealing with large structures or long type names. It is common for newer developers to assume the above output is some kind of log spam and not even realize it contains exactly the information they are looking for.

## Proposed solution

Conform `EncodingError` and `DecodingError` to `CustomDebugStringConvertible` and provide a clean, readable debug description for each.

Complete examples of the before/after diffs are available in the description of the [implementation pull request](https://github.com/swiftlang/swift/pull/80941) that accompanies this proposal.

**Note 1:** This proposal is _not_ intended to specify an exact output format, and any examples are not a guarantee of current or future behavior. You are still free to inspect the contents of thrown errors directly if you need to detect specific problems.

**Note 2:** The output could be further improved by modifying `JSONDecoder` to write a better debug description. See [Future Directions](#future-directions) for more.

## Detailed design

```swift
@available(SwiftStdlib 6.2, *)
extension EncodingError: CustomDebugStringConvertible {
  public var debugDescription: String {...}
}

@available(SwiftStdlib 6.2, *)
extension DecodingError: CustomDebugStringConvertible {
  public var debugDescription: String {...}
}
```

## Source compatibility

The new conformance changes the result of converting an `EncodingError` or `DecodingError` value to a string. This changes observable behavior: code that attempts to parse the result of `String(describing:)` or `String(reflecting:)` can be misled by the change of format.

However, the documentation of these interfaces explicitly state that when the input type conforms to none of the standard string conversion protocols, then the result of these operations is unspecified.

Changing the value of an unspecified result is not considered to be a source incompatible change.

## ABI compatibility

The proposal conforms two previously existing stdlib types to a previously existing stdlib protocol. This is technically an ABI breaking change: on ABI-stable platforms, we may have preexisting Swift binaries that implement a retroactive `CustomDebugStringConvertible` conformance, or binaries that assume that the existing error types do _not_ conform to the protocol.

We do not expect this to be an issue in practice, since checking an arbitrary error for conformance to `CustomDebugStringConvertible` at run-time seems unlikely. In the event that it now conforms where it didn't before, it will presumably use the new implementation instead of whatever fallback was being provided previously.

## Implications on adoption

### Conformance to `CustomDebugStringConvertible`

The conformance to `CustomDebugStringConvertible` is not backdeployable. As a result, code that runs on ABI-stable platforms with earlier versions of the standard library won't output the new debug descriptions.

### `debugDescription` Property

It is technically possible to backdeploy the `debugDescription` property, but without the protocol conformance, it is of limited utility.

## Future directions

### Better error generation from Foundation encoders/decoders

The debug descriptions generated in Foundation sometimes contain the same information as the new debug descriptions from this proposal. A future change to the standard JSON and Plist encoders and decoders could provide more compact debug descriptions once they can be sure they have the new standard library descriptions available. They could also use a more compact description when rendering the description of a `CodingKey`. Take, for example:

```
Debug description: No value associated with key CodingKeys(stringValue: "population", intValue: nil) ("population").
```

The `CodingKeys(stringValue: "population", intValue: nil) ("population")` part is coming from the default `description` of `CodingKey`, plus an extra parenthesized string value at the end for good measure. The Foundation (de|en)coders could construct a more compact description that does not repeat the key, just like we do within this proposal in the context of printing a coding path.

### Print context of surrounding lines in source data

When a decoding error occurs, in addition to printing the path, the error message could include some surrounding lines from the source data. This was explored in this proposal's antecedent, [UsefulDecode](https://github.com/ZevEisenberg/UsefulDecode). But more detailed messages would require passing more context data from the decoder and changing the public interface of `DecodingError` to carry more data. This option is best left as something to think about as [we design `Codable`'s successor](https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585). But just to give an example of the _kind_ of context that could be provided (please do not read anything into the specifics of the syntax; this is a sketch, not a proposal):

```
Value not found: expected 'name' (String) at [0]/address/city/birds/[1]/name, got:
{
  "feathers" : "some",
  "name" : null
}
```

## Alternatives considered

We could conform `EncodingError` and `DecodingError` to `CustomStringConvertible` instead of `CustomDebugStringConvertible`. The use of the debug-flavored protocol emphasizes that the new descriptions aren't intended to be used outside debugging contexts. This is in keeping with the precedent set by [SE-0445](0445-string-index-printing.md).

We could change `CodingKey.description` to return the bare string or int value, which would improve the formatting and reduce duplication as seen in [Proposed solution](#proposed-solution). But changing the exsting implementation of an existing public method seems needlessly risky, as existing code may (however inadvisably) be depending on the format of the current `description`. Additionally, the encoders and decoders in Foundation should not depend on implementation details of `CodingKey.description` that are not guaranteed. If we want the encoders/decoders to produce better formatting, they should be responsible for generating those strings directly. See [further discussion in the PR](https://github.com/swiftlang/swift/pull/80941#discussion_r2064277369).

## Acknowledgments

This proposal follows in the footsteps of [SE-0445](0445-string-index-printing.md). Thanks to [Karoy Lorentey](https://github.com/lorentey) for writing that proposal, and for flagging it as similar to this one.

Thanks to Kevin Perry [for suggesting](https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585/77) that this would make a good standalone change regardless of the direction of future serialization tools, and for engaging with the PR from the beginning.
