# Formalized Ordering
* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Robert Widmann](https://github.com/codafi), [Jaden Geller](https://github.com/jadengeller), [Harlan Haskins](https://github.com/harlanhaskins), [Pyry Jahkola](https://github.com/pyrtsa)
* Status: **Awaiting review**
* Review manager: TBD


## Introduction

This proposal cleans up the semantics of ordering relations in the standard library.  Our goal is to formalize the total ordering semantics of the `Comparable` protocol and still provide accessible ordering definitions for types without total ordering semantics.

## Motivation

The standard comparison operators have an intuitive meaning to programmers.  Swift encourages encoding that in an implementation of `Comparable` that respects the rules of a [total order](https://en.wikipedia.org/wiki/Total_order).  The standard library takes advantage of these rules to provide consistent implementations for sorting and searching generic collections of `Comparable` types.

Not all types behave so well in this framework, unfortunately.  There are cases where the semantics of a total order cannot apply and still maintain the traditional definition of “comparison” over these types.  Take, for example, sorting an array of `Float` s.  Today, `Float` ‘s instance of `Comparable` follows IEEE-754 and returns `false` for all comparisons of `NaN` .   In order to sort this array, `NaN` s are considered outside the domain of `<` , and the order of a “sorted” array containing them is undefined.

In addition, generic algorithms in the Swift Standard Library that make use of the current `Comparable`  protocol may have to make twice as many comparisons to request the ordering of values with respect to each other than they should.  Having a central operation to return information about the ordering of values once should provide a speedup for these operations.

In the interest of cleaning up the semantics of `Comparable` types of all shapes and sizes and their uses in the Swift Standard Library, this proposal is going to re-arrange the requirements of the `Comparable` and `Equatable` protocols.

## Proposed solution

### Equatable

The interface of `Equatable` remains unchanged under this proposal. Equatable types should still respect the equivalence laws of *reflexivity* (`a == a`), *symmetry* (`a == b` iff `b == a`), and *transitivity* (if `a == b` and `b == c`, then `a == c`). Further, `!=` remains a top-level binary operator for which `a != b` iff `!(a == b)`.

Types containing properties *inessential to equality*, however, are allowed to retain their notion of identity. For example `Array`'s `capacity` isn't considered for equality; and `-0.0 == 0.0` and `"ä" == "a\u{308}"`, while `(-0.0).sign != (0.0).sign` and `"ä".utf8.count != "a\u{308}".utf8.count`.

IEEE-754 floating point numbers are allowed to break the reflexivity law by defining that `.nan != x` for any value of `x`, which is the standard behaviour documented in IEEE-754 and implemented the same way in other programming languages.

### Comparable

The `Comparable` protocol will now require (without default implementation provided) a single operator definition: `<=>` — the comparison operator.  From this, all other comparison operators will be derived so as to respect the total order semantics of `Comparable`:

To maintain compatibility with IEEE-754, the interface of `Comparable` also contains as customization points the operators `<`, `<=`, and `==` (derived from `Equatable`) as well as the static binary functions `_min(_:_:)` and `_max(_:_:)`. User-defined types are recommended against overriding the default implementations.

The uncustomizable top-level binary comparison operators `a > b` and `a >= b` are implemented as synonyms to `b < a` and `b <= a`, respectively.

### Standard Library

Unlike a previous revision of this proposal, standard library algorithms specific to `FloatingPoint` remain unchanged.

Overloads of `<=>` for tuples of `Comparable` elements are provided up to a library-defined arity.

The intent of this proposal is to later augment the standard library so that functions that take an ordering predicate `by: (T, T) -> Bool`  will have an overload `ordering: (T, T) -> Ordering` that will provide a — potentially — more efficient implementation. A list of such functions is provided in Future directions.

## Detailed design

The `Comparable` protocol will be amended by taking away `>` and `>=`, adding customisation points `_min(_:_:)`, and `_max(_:_:)`, and introducing the ordering operator `<=>` that makes use of the `Ordering` enum defined below.

```swift
enum Ordering : Equatable {
  case ascending
  case equal
  case descending
}

infix operator <=> { associativity none precedence 130 }

public protocol Comparable : Equatable {
  // Implementation required:
  static func <=>(lhs: Self, rhs: Self) -> Ordering

  // Default implementations provided:
  static func == (lhs: Self, rhs: Self) -> Bool // derived from Equatable
  static func <  (lhs: Self, rhs: Self) -> Bool
  static func <= (lhs: Self, rhs: Self) -> Bool
  static func _min(_ lhs: Self, _ rhs: Self) -> Self
  static func _max(_ lhs: Self, _ rhs: Self) -> Self
}
```

The `<=>` operator defines a relationship between `==` and `<=>` such that `a == b` iff `(a <=> b) == .equal`, unless `Self` chooses to break the semantics in the way of IEEE-754. Likewise, it should hold that `(a <=> b) == .ascending` iff `a < b`, and `(a <=> b) != .descending` iff `a <= b`.

The `_min(_:_:)` and `_max(_:_:)` functions should return the lesser or greater of the two operands, respectively, while in case of equal arguments, `_min(_:_:)` should favour the left-hand side and `_max(_:_:)` the right-hand side to retain identity, as presently explained in [this comment](https://github.com/apple/swift/blob/4614adc16168d612b6fc7e7a161dd5b6b34be704/stdlib/public/core/Algorithm.swift#L17-L20). Making them customization points of `Comparable`, we get to fix their behaviour in the presense of unorderable values ([SR-1011](https://bugs.swift.org/browse/SR-1011)).

Most user types should only implement `<=>` and leave the other members of `Equatable` and `Comparable` to their default implementations. Note that even `==` has a sane default implementation if `Self` is made `Comparable`:

```swift
// Default implementations, which should be used for most Comparable types:
extension Comparable {
  static func == (l: Self, r: Self) -> Bool { return (l <=> r) == .equal }
  static func <  (l: Self, r: Self) -> Bool { return (l <=> r) == .ascending }
  static func <= (l: Self, r: Self) -> Bool { return (l <=> r) != .descending }
  static func _min(_ l: Self, _ r: Self) -> Self { return r < l ? r : l }
  static func _max(_ l: Self, _ r: Self) -> Self { return r < l ? l : r }
}

// Unoverridable top-level operators and functions for Comparable:
public func >  <T : Comparable>(l: T, r: T) -> Bool { return r < l }
public func >= <T : Comparable>(l: T, r: T) -> Bool { return r <= l }
public func min<T : Comparable>(_ l: T, _ r: T) -> T { return T._min(l, r) }
public func max<T : Comparable>(_ l: T, _ r: T) -> T { return T._max(l, r) }
```

### Handling of floating point comparisons

*The following text is written in terms of `Double` but other floating-point types (`Float`, `Float80`) are proposed the same treatment.*

The IEEE-754 floating point specification has two oddities when it comes to orderability: there are two zeros (`0.0` and `-0.0`) which are considered equal to each other, and there are _multiple_ not-a-number values `x` for which `x.isNaN == true` and `x != y` with any value of `y`, even `x` itself. (Remark: the most common NaN value is obtained by the static property `Double.nan`.)

The interface of `Comparable` is designed so that `<=>` alone is able to produce a total order among all possible `Double` values, sorting negative NaNs less than any other values, and positive NaNs greater than any other. Otherwise, within the range of totally ordered floating point values, `-Double.infinity ... Double.infinity`, the result of `a <=> b` remains in full agreement with the laws of `a < b`, `a <= b`, and `a == b`.

The suggested implementation of `Double : Comparable` makes `<=>` distinguish between every different `bitPattern` of NaN:

```swift
extension Double : Comparable {
  public static func <=> (l: Double, r: Double) -> Ordering {
    func ordinal(_ x: UInt64) -> UInt64 {
      return x < 0x80000000_00000000 ? x + 0x7fffffff_ffffffff : ~x
    }
    return ordinal(l.bitPattern) <=> ordinal(r.bitPattern)
  }
  public static func == (l: Double, r: Double) -> Bool { return Builtin.eq(l, r) }
  public static func <  (l: Double, r: Double) -> Bool { return Builtin.lt(l, r) }
  public static func <= (l: Double, r: Double) -> Bool { return Builtin.le(l, r) }
  public static func _min(l: Double, r: Double) -> Double { return Builtin.fmin(l, r) }
  public static func _max(l: Double, r: Double) -> Double { return Builtin.fmax(l, r) }
}

// Likewise:
extension Float : Comparable { ... }
extension Float80 : Comparable { ... }
```

### Tuples and order reversal

Due to missing language support, tuples of `Comparable` elements cannot be `Comparable` themselves, but in the spirit of [SE-0015](https://github.com/apple/swift-evolution/blob/master/proposals/0015-tuple-comparison-operators.md), such tuples are given their overloads of `<=>` up to a standard library defined maximum arity:

```swift
public func <=> <A : Comparable, B : Comparable>(lhs: (A, B), rhs: (A, B)) -> Ordering {
  let a = lhs.0 <=> rhs.0
  if a != .equal { return a }
  let b = lhs.1 <=> rhs.1
  if b != .equal { return b }
  return .equal
}

// Similarly for <A : Comparable, B : Comparable, C : Comparable>, etc.
```

To simplify the reversal of a given ordering operation, two members of `Ordering` are provided in an extension:

```swift
extension Ordering {
  public static func reversing<T : Comparable>(_ ordering: (T, T) -> Ordering)
    -> (T, T) -> Ordering
  {
    return { l, r in ordering(r, l) }
  }

  public var reversed: Ordering {
    switch self {
    case .ascending:  return .descending
    case .equal:      return .equal
    case .descending: return .ascending
    }
  }
}
```

### Foundation

In addition, `Foundation` code will now bridge `NSComparisonResult` to `Ordering`  allowing for a fluid, natural, and safe API.

## Impact on existing code

The biggest drawback of the proposed design is the large surface area of `Comparable`'s interface, as well as the possibility of overriding the comparison operators by mistake. On the other hand, since the required `<=>` operator is new and affects all users porting their previously `Comparable` data types to Swift 3, we can use documentation to suggest removing the redundant (and possibly faulty) implementations of other comparison operators.

Existing `Equatable` but **not** `Comparable` types that define an equivalence relation with `==` will remain unchanged.

Existing `Comparable` types that define a total ordering with `<` will need to implement `<=>`  and should remove their existing implementation of any comparison operators, including `==`.  All other existing `Comparable`  types should implement `<=>`  that provides a total ordering, or should drop their `Comparable` conformance.

Before:

```swift
struct Date: Comparable {
  let year: Int
  let month: Int
  let day: Int
}

func ==(lhs: Date, rhs: Date) -> Bool {
  return lhs.year == rhs.year
    && lhs.month == rhs.month
    && lhs.day == rhs.day
}

func <(lhs: Date, rhs: Date) -> Bool {
  if lhs.year != rhs.year {
    return lhs.year < rhs.year
  } else if lhs.month != rhs.month {
    return lhs.month < rhs.month
  } else {
    return lhs.day < rhs.day
  }
}
```

After, using the tuple overload of `<=>`:

```swift
struct Date: Comparable {
  let year: Int
  let month: Int
  let day: Int

  static func <=> (lhs: Date, rhs: Date) -> Ordering {
    return (lhs.year, lhs.month, lhs.day)
       <=> (rhs.year, rhs.month, rhs.day)
  }

  // // Explicit version:
  // static func <=> (lhs: Date, rhs: Date) -> Ordering {
  //   let yearResult = lhs.year <=> rhs.year
  //   guard case .equal = yearResult else { return yearResult }
  //   let monthResult = lhs.month <=> rhs.month
  //   guard case .equal = monthResult else { return monthResult }
  //   return lhs.day <=> rhs.day
  // }
}
```

## Alternatives considered

A previous design of this proposal suggested a strict total order upon `Comparable`. While that would make generic algorithms more correct, the definition ended up fighting against the expected behaviour of floating point numbers.

An alternative design that better matches the existing arithmetic-related protocols in Swift is one that uses a member function.

```swift
public protocol Comparable: Equatable {
  func compare(to: Self) -> Ordering
}
```

However, while this API does read better than an operator, we believe that this imposes a number of artificial restrictions (especially in light of [SE-0091](https://github.com/apple/swift-evolution/blob/master/proposals/0091-improving-operators-in-protocols.md))

1. There is no way to use `Comparable.compare` as a higher-order function in a non-generic context.
2. If a member is desired, it can be provided in a protocol extension and defined in terms of the ordering operator; to each according to their need.
3. The existing tuple overloads cannot be expressed with a member function.

One other that Rust has adopted is the inclusion of `PartialEquatable` and `PartialComparable`  as ancestors of their flavor of `Equatable` and `Comparable` .  Having protocols to organize and catalogue types that can only guarantee partial equivalence and ordering relations is a good approach for modularity but clutters the standard library with two new protocols for which few useful algorithms could be written against.

## Future directions

That the default `sort()` compares by `<` and not `<=>` should be considered a bug to be fixed in a future version of Swift. Using `<=>` will make `sort()` well-behaved in the presense of NaN. However, given that the current behaviour is to produce an unspecified order, the fix is additive and can be slipped past Swift 3.

With `<=>` in place, several present and future standard library algorithms involving a `<T : Comparable>` requirement will possibly benefit from knowing the total ordering of two operands at once. This is a list of possible such functions (taking `Array` as example), to be proposed separately as an additive change:

```swift
extension Array {
  // Sorting

  mutating func sort(ordering: @noescape (Element, Element) throws -> Ordering) rethrows
  func sorted(ordering: @noescape (Element, Element) throws -> Ordering) rethrows -> [Element]
  mutating func stableSort(ordering: @noescape (Element, Element) throws -> Ordering) rethrows
  func stableSorted(ordering: @noescape (Element, Element) throws -> Ordering) rethrows -> [Element]

  /// Reorders the elements of the collection such that all the elements
  /// returning `.ascending` are moved to the start of the collection, and the
  /// elements returning `.descending` are moved to the end of the collection.
  /// - Returns: the range of elements for which `ordering(x) == .equal`.
  mutating func partition(ordering: @noescape (Iterator.Element) throws -> Ordering) rethrows -> Range<Index>

  // Binary search

  func bisectedIndex(ordering: @noescape (Element) throws -> Ordering) rethrows -> Index?
  func lowerBound(ordering: @noescape (Element) throws -> Ordering) rethrows -> Index
  func upperBound(ordering: @noescape (Element) throws -> Ordering) rethrows -> Index
  func equalRange(ordering: @noescape (Element) throws -> Ordering) rethrows -> Range<Index>
}
```

