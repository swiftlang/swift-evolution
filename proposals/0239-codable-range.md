# Add Codable conformance to Range types

* Proposal: [SE-0239](0239-codable-range.md)
* Authors: [Dale Buckley](https://github.com/dlbuckley), [Ben Cohen](https://github.com/airspeedswift), [Maxim Moiseev](https://github.com/moiseev)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Implementation: [apple/swift#19532](https://github.com/apple/swift/pull/19532),
                  [apple/swift#21857](https://github.com/apple/swift/pull/21857)
* Status: **Implemented (Swift 5.0)**
* Review: [Discussion thread](https://forums.swift.org/t/se-0239-add-codable-conformance-to-range-types/18794/51)


## Introduction

[SE-0167](0167-swift-encoders.md) introduced `Codable` conformance for some types in the standard
library, but not the `Range` family of types. This proposal adds that
conformance.

Swift-evolution thread: [Range conform to Codable](https://forums.swift.org/t/range-conform-to-codable/15552)

## Motivation

`Range` is a very useful type to have conform to `Codable`. A good usage example is a range being sent to/from a client/server to convey a range of time using `Date`, or a safe operating temperature range using `Measurement<UnitTemperature>`.

## Proposed solution

The following Standard Library range types will gain `Codable` conformance
when their `Bound` is also `Codable`:

 * `Range`
 * `ClosedRange`
 * `PartialRangeFrom`
 * `PartialRangeThrough`
 * `PartialRangeUpTo`

These types will use an unkeyed container of their lower/upper bound (in sorted order, in cases of `Range` and `ClosedRange`).

In addition, `ContiguousArray` is also missing a conformance to `Codable`, which will be added.

## Effect on ABI stability, resilience, and source stability

This is a purely additive change, and so has no impact.

## Alternatives considered

One area of concern mentioned during the discussion is that of
potential data corruption. Consider this: if an application implements its own
`Codable` conformance for `Range` or `ClosedRange` (which is, by the way, not
recommended, as both the protocol and the type are defined in the standard
library), there might be data permanently stored somewhere (in the database, in
a JSON or PLIST file, etc.) which was serialized using that conformance. Unless
the serialization format is exactly the same as the one used in the standard
library, that data will be considered invalid.

When this proposal is implemented, any `Codable` conformance to the `Range` type
outside standard library will result in a compiler error as duplicate
conformance. At which point, we suggest the following course of action to avoid
data loss.

1. Define your own type wrapping `Range`.

    ```swift
    public struct MyRangeWrapper<Bound>
    where Bound: Comparable {
    public var range: Range<Bound>
    }
    ```

2. Port `Codable` conformance from `Range` to this new type.

    ```swift
    extension MyRangeWrapper {
      enum CodingKeys: CodingKey {
        case lowerBound
        case upperBound
      }
    }

    extension MyRangeWrapper: Decodable
    where Bound: Decodable {
      public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(Bound.self, forKey: .lowerBound)
        let upperBound = try container.decode(Bound.self, forKey: .upperBound)
        self.range = lowerBound ..< upperBound
      }
    }

    ```

    Note that unless you wish to keep using this serialization format in the
    future, and are OK with using what's provided by the standard library, only
    the `Decodable` conformance is needed for data migration purposes.

3. Support both old and new formats when deserializing your data that contains
   ranges.

   ```swift
    extension JSONDecoder {
      func decodeRange<Bound>(
        _ type: Range<Bound>.Type, from data: Data
      ) throws -> Range<Bound>
      where Bound: Decodable {
        do {
          return try self.decode(Range<Bound>.self, from: data)
        }
        catch DecodingError.typeMismatch(_, _) {
          return try self.decode(MyRangeWrapper<Bound>.self, from: data).range
        }
      }
    }
    ```
