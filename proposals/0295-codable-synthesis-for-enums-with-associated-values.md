# Codable synthesis for enums with associated values

* Proposal: [SE-0295](0295-codable-synthesis-for-enums-with-associated-values.md)
* Authors: [Dario Rexin](https://github.com/drexin)
* Review Manager: [Saleem Abdulrasool](https://github.com/compnerd)
* Status: **Scheduled for Review (January 21...31, 2021)**
* Implementation: [apple/swift#34855](https://github.com/apple/swift/pull/34855)
* Pitch: [Forum Discussion](https://forums.swift.org/t/codable-synthesis-for-enums-with-associated-values/41493)
* Previous Review: [Forum Discussion](https://forums.swift.org/t/se-0295-codable-synthesis-for-enums-with-associated-values/42408)

## Introduction

Codable was introduced in [SE-0166](https://github.com/apple/swift-evolution/blob/master/proposals/0166-swift-archival-serialization.md)
with support for synthesizing `Encodable` and `Decodable` conformance for
`class` and `struct` types, that only contain values that also conform
to the respective protocols.

This proposal will extend the support for auto-synthesis of these conformances
to enums with associated values.

## Motivation

Currently auto-synthesis only works for enums conforming to `RawRepresentable`.
There have been discussions about adding general support for enums in the past,
but the concrete structure of the encoded values was never agreed upon.
We believe that having a solution for this is an important quality of life
improvement.

## Proposed solution

### Structure of encoded enums

The following enum with associated values

```swift
enum Command: Codable {
  case load(key: String)
  case store(key: String, value: Int)
}
```

would be encoded to

```json
{
  "load": {
    "key": "MyKey"
  }
}
```

and 

```json
{
  "store": {
    "key": "MyKey",
    "value": 42
  }
}
```

The top-level container contains a single key that matches the name of the enum case,
which points to another container that contains the values as they would be encoded
for structs and classes.

Associated values can also be unlabeled, in which case they will be encoded into an
array instead, or just the raw value if only one parameter is present.

```swift
enum Command: Codable {
  case load(String)
  case store(String, value: Int)
}
```

would encoded to

```json
{
  "load": "MyKey"
}
```

and 

```json
{
  "store": [
    "MyKey",
    42
  ]
}
```

An enum case without associated values would be encoded as `true` value.
i.e.

```swift
enum Command: Codable {
  case dumpToDisk
}
```

would encode to:

```json
{
  "dumpToDisk": true
}
```

With the exception of the last case, this solution is closely following the default behavior of the Rust library [serde](https://serde.rs/container-attrs.html).

### User customization

For the existing cases users can customize which properties are included in the encoded respresentation
and map the property name to a custom name for the encoded representation by providing a custom `CodingKeys`
declaration instead of having the compiler generate one. The same should apply to the enum case.
Given that enums are encoded into a nested structure, there are multiple `CodingKeys` declarations. One
that contains the keys for each of the enum cases, which as before is called `CodingKeys`, and one for each case that contain the keys for the
associated values, that are prefixed with the capilized case name, e.g. `LoadCodingKeys` for `case load`.

**Example**

```swift
enum Command: Codable {
  case load(key: String)
  case store(key: String, value: Int)
}
```

Would have the compiler generate the following `CodingKeys` declarations:

```swift

// contains keys for all cases of the enum
enum CodingKeys: CodingKey {
  case load
  case store
}

// contains keys for all associated values of `case load`
enum LoadCodingKeys: CodingKey {
  case key
}

// contains keys for all associated values of `case store`
enum StoreCodingKeys: CodingKey {
  case key
  case value
}
```

Since cases with unlabeled parameters encode into unkeyed containers,
no `CodingKeys` enum will be generated for them.

Users can define custom `CodingKeys` declarations for all, or a subset
of the cases. If some of the cases in an enum should not be codable,
they can be excluded from the `CodingKeys` declaration.

**Example**

```swift
enum Command: Codable {
  case load(key: String)
  case store(key: String, value: Int)
  case dumpToDisk

  enum CodingKeys: CodingKey {
    case load
    case store
    // don't include `dumpToDisk`
  }
}
```

The compiler will now only synthesize the code for the `load` and `store`
cases. An attempt to en- or decode a `dumpToDisk` value will cause an error
to be thrown.

Customizing which values will be included follows the same rules as the
existing functionality. Values that are excluded must have a default value
defined if a `Decodable` conformance should be synthesized. If only `Encodable`
is synthesized, this restriction does not apply.

**Example**

```swift
enum Command: Codable {
  case load(key: String, someLocalInfo: Int)

  // invalid, because `someLocalInfo` has no default value
  enum LoadCodingKeys: CodingKey {
    case key
  }
}
```

```swift
enum Command: Codable {
  case load(key: String, someLocalInfo: Int = 0)

  // valid, because `someLocalInfo` has a default value
  enum LoadCodingKeys: CodingKey {
    case key
  }
}
```

```swift
enum Command: Codable {
  case load(key: String)

  // invalid, because `someUnknownKey` does not map to a parameter in `load`
  enum LoadCodingKeys: CodingKey {
    case key
    case someUnknownKey
  }
}
```

Keys can be mapped to other names by conforming to `RawRepresentable`:

**Example**

```swift
enum Command: Codable {
  case load(key: String)

  enum CodingKeys: String, CodingKey {
    case load = "lade"
  }

  enum LoadCodingKeys: String, CodingKey {
    case key = "schluessel"
  }
}
```

would encode to:

```json
{
  "lade": {
    "schluessel": "MyKey"
  }
}
```

### Unsupported cases

This proposal specifically does not support auto-synthesis for enums with overloaded case identifiers. This decision has been made because there is no clear way to support the feature, while also allowing the model to evolve, without severe restrictions. The separate cases in an enum typically have different semantics associated with them, so it is crucial to be able to properly identify the different cases and reject unknown cases.

In this proposal, we are using keys as descriminators. For overloaded case names that would not be sufficient to identify the different overloads. An alternative would be to use the full name, including labels, e.g. `"store(key:,value:)"` for `case store(key: String, value: Int)`. This leads to several problems.

1. Not a valid enum case identifier, so no user customization possible
2. Not forward/backward compatible because it changes when parameters are added
3. Very Swift specific, making interop with non-Swift systems awkward

An alternative solution would be to match the keys against the parameter names when decoding an object. This approach also has issues.

1. Overloads can share paramter names

This causes ambiguity when a message contains additional keys:

```swift
enum Test: Codable {
  case x(y: Int)
}
```

```json
{
  "x": {
    "y": 42,
    "z": "test"
  }
}
```

This could either mean that a parameter has been added to the existing case in a new code version, which should be ok under backwards compatibility rules, but could also mean that an overloaded has been added that partially matches the original case. If it is a different case, we should reject the message, but there is no way for the old version to decide this.

Another case that causes ambiguity is an overload that has an additional, optional parameter:

```swift
enum Test: Codable {
  case x(y: Int)
  case x(y: Int, z: String?)
}
```

If `z` is `nil`, this case encodes to the same as the first, so even in the same code version there can be ambiguity.

2. Order of key value pairs is no necessarily guaranteed

This means the following definition leads to ambiguity when decoding:

```swift
enum Test: Codable {
  case x(y: Int, z: String)
  case x(z: String, y: Int)
}
```

The following JSON would match both cases

```json
{
  "x" : {
    "y": 42,
    "z": "test"
  }
}
```

## Source compatibility

Existing source is not affected by these changes.

## Effect on ABI stability

None

## Effect on API resilience

None

## Alternatives considered

Previous discussions in the forums have been considered, specifically separating
the discriminator and value into individual key/value pairs discussed in [this forum thread](https://forums.swift.org/t/automatic-codable-conformance-for-enums-with-associated-values-that-themselves-conform-to-codable/11499).
While we do believe that there is value in doing this, we think that the default
behavior should more closely follow the structure of the types that are encoded.
A future proposal could add customization options to change the structure to meet
individual requirements.

### Parameterless cases

Alternative ways to encode these cases have been discussed and the following problems have been found:

1. Encode as plain values, as we do today with `RawRepresentable`

The problem with this is that `Decoder` does not have APIs to check which type of container is present and adding such APIs would be a breaking change. The existing APIs to read containers are `throws`, but it is not specified in which cases an error should occur. 

2. Encode as empty `Keyed-` / `UnkeyedContainer`

It was initially proposed to encode this case as an empty `KeyedContainer`, but in the first review it was pointed out that there is no good justification to favor `Keyed-` over `UnkeyedContainer` for reasons of backwards compatibility.

3. Encode as `nil`

This representation is problematic, because `Encoder` implementations can decide to drop `nil` values, which would also mean losing the key and with it the ability to identify the case.
