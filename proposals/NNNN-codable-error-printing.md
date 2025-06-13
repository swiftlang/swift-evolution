# Improve `EncodingError` and `DecodingError`'s printed descriptions

* Proposal: [SE-NNNN](NNNN-codable-error-printing.md)
* Authors: [Zev Eisenberg](https://github.com/ZevEisenberg)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: https://github.com/swiftlang/swift/pull/80941
* Review: TBD

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

Conform `EncodingError` and `DecodingError` to `CustomDebugStringConvertible` and provide a clean, readable debug description for each. Here is an example of the proposed change for the same decoding error as above:

```
Key 'population' not found in keyed decoding container.
Debug description: No value associated with key CodingKeys(stringValue: "population", intValue: nil) ("population").
Path: [0]/home/country
```

(Note: the output could be further improved by modifying `JSONDecoder` to write a better debug description. See [Future Directions](#future-directions) for more.)

### Structure

1. Description using information we know from the associated values of the error enum itself.
1. The debug description that was passed to the error, if it is not empty.
1. The underlying error, if it is non-nil.
1. The coding path, neatly formatted, if it is non-empty. String keys are presented as-is, and numeric indices are presented in square brackets like `[2]` to differentiate them from string keys.

More complete examples of the before/after diffs are available in the description of the pull request: https://github.com/swiftlang/swift/pull/80941.

The path formatting is especially improved. Comparing the examples from above:

```diff
-[_CodingKey(stringValue: "Index 0", intValue: 0), CodingKeys(stringValue: "home", intValue: nil), CodingKeys(stringValue: "country", intValue: nil)]
+Path: [0]/home/country
```

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

The proposal retroactively conforms two previously existing standard types to a previously existing standard protocol. This is technically an ABI breaking change: on ABI-stable platforms, we may have preexisting Swift binaries that assume that `EncodingError is CustomDebugStringConvertible` or `DecodingError is CustomDebugStrinConvertible` returns `false`, or ones that are implementing this conformance on their own.

We do not expect this to be an issue in practice.

## Implications on adoption

[Unsure what to add here. I see stuff in [SE-0445](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0445-string-index-printing.md#implications-on-adoption), but I'm not sure how much of that applies here. I don't know if I need to be doing the `@backDeployed` things that proposal mentions, and when I look at the code from the PR, I see `@_alwaysEmitIntoClient // FIXME: Use @backDeployed`.]

## Future directions

### Better error generation from Foundation encoders/decoders

The debug descriptions generated in Foundation sometimes contain the same information as the new debug descriptions from this proposal. A future change to the standard JSON and Plist encoders and decoders could provide more compact debug descriptions once they can be sure they have the new standard library descriptions available. They could also use a more compact description when rendering the description of a `CodingKey`. Using part of the example from above:

```
Debug description: No value associated with key CodingKeys(stringValue: "population", intValue: nil) ("population").
```

The `CodingKeys(stringValue: "population", intValue: nil) ("population")` part is coming from the default `description` of `CodingKey`, plus an extra parenthesized string value at the end for good measure. The Foundation (de|en)coders could construct a more compact description that does not repeat the key, just like we do within this proposal in the context of printing a coding path.

### Print context of surrounding lines in source data

When a decoding error occurs, in addition to printing the path, the error message could include some surrounding lines from the source data. This was explored in this proposal's antecedent, [UsefulDecode](https://github.com/ZevEisenberg/UsefulDecode). But that requires passing more context data from the decoder and changing the public interface of `DecodingError` to carry more data. This option is probably best left as something to think about as [we design `Codable`'s successor](https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585). But just to give an example of the _kind_ of context that could be provided (please do not read anything into the specifics of the syntax; this is a sketch, not a proposal):

```
Value not found: expected 'name' (String) at [0]/address/city/birds/[1]/name, got:
{
  "feathers" : "some",
  "name" : null
}
```

## Alternatives considered

The original version of this proposal suggested conforming `EncodingError` and `DecodingError` to `CustomStringConvertible`, not `CustomDebugStringConvertible`. The change to the debug-flavored protocol emphasizes that the new descriptions aren't intended to be used outside debugging contexts. This is in keeping with the precedent set by [SE-0445](0445-string-index-printing.md).

The original version also proposed changing `CodingKey.description` to return the bare string or int value, but changing the exsting implementation of an existing public method was deemed too potentially dangerous.

In terms of formatting, we could do away with the square brackets around integers and just interpolate them in directly:

```diff
-path/to/thing/[2]/[4]/more/stuff
+path/to/thing/2/4/more/stuff
```

## Acknowledgments

This proposal lifts large portions almost verbatim from [SE-0445](0445-string-index-printing.md). Thanks to [Karoy Lorentey](https://github.com/lorentey) for writing that proposal, and for flagging it as similar to this one.

Thanks to Kevin Perry [for suggesting](https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585/77) that this would make a good standalone change regardless of the direction of future serialization tools, and for engaging with the PR from the beginning.
