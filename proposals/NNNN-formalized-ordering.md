# Formalized Ordering
* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Robert Widmann](https://github.com/codafi), [Jaden Geller](https://github.com/jadengeller), [Harlan Haskins](https://github.com/harlanhaskins)
* Status: **Awaiting review**
* Review manager: TBD


### Introduction

This proposal cleans up the semantics of ordering relations in the standard library.  Our goal is to formalize the total ordering semantics of the `Comparable` protocol and still provide accessible ordering definitions for types without total ordering semantics.

### Motivation

The standard comparison operators have an intuitive meaning to programmers.  Swift encourages encoding that in an implementation of `Comparable` that respects the rules of a [total order](https://en.wikipedia.org/wiki/Total_order).  The standard library takes advantage of these rules to provide consistent implementations for sorting and searching generic collections of `Comparable` types.  

Not all types behave so well in this framework, unfortunately.  There are cases where the semantics of a total order cannot apply and still maintain the traditional definition of “comparison” over these types.  Take, for example, sorting an array of `Float` s.  Today, `Float` ‘s instance of `Comparable` follows IEEE-754 and returns `false` for all comparisons of `NaN` .   In order to sort this array, `NaN` s are considered outside the domain of `<` , and the order of a “sorted” array containing them is undefined.

In addition, generic algorithms in the Swift Standard Library that make use of the current `Comparable`  protocol may have to make twice as many comparisons to request the ordering of values with respect to each other than they should.  Having a central operation to return information about the ordering of values once should provide a speedup for these operations.

In the interest of cleaning up the semantics of `Comparable` types of all shapes and sizes and their uses in the Swift Standard Library, this proposal is going to re-arrange the requirements of the `Comparable` and `Equatable` protocols.

### Proposed solution

- Equatable

The `Equatable` protocol will now dispatch through a static function, spelled `areSame(_:_:)`  that is meant to respect the rules of an [equivalence relation](https://en.wikipedia.org/wiki/Equivalence_relation) - reflexivity, transitivity, and symmetry.  The semantics of `areSame(_:_:)`  are exactly the required semantics of `==`  today.

The `==` operator will now be a free function that dispatches through `areSame(_:_:)`  by default.  If semantics other than a total order are needed, `==`  can be defined specifically for those types.  


- Comparable

The `Comparable` protocol will now require a single operator definition: `<=>`  - the comparison operator.  From this, all other comparison operators will be derived so as to respect the total order semantics of `Comparable` .


- Standard Library

The Swift Standard Library has a number of functions whose semantics will change for `FloatingPoint`  types to accommodate the new total ordering guarantees.  In addition, functions that take an ordering predicate `by: (Self, Self) → Bool`  will have an overload `by: (Self, Self) → Ordering` that will provide a - potentially - more efficient implementation.

### Detailed design

The `Comparable` protocol will be amended to substitute the existing operator requirements for the ordering operator `<=>`  that makes use of the `Ordering` enum defined below.

```swift
enum Ordering: Equatable {
  case ascending
  case same
  case descending
}


infix operator <=> { associativity none; precedence 130 }

public protocol Comparable: Equatable {
  static func <=>(lhs: Self, rhs: Self) -> Ordering
}

extension Comparable {
  public static func areSame(lhs: Self, rhs: Self) -> Bool {
    return (lhs <=> rhs) == .same
  }
}
```

This operator defines a relationship between `areSame(_:_:)`  and `<=>`  such that `T.areSame(a, b)` iff `(a <=> b) == .same` .  There is, however, no such relationship between the compare operator `<=>` and `==` or `areSame(_:_:)`  and `==` .  For `Comparable` types, `==` is equally decoupled from the ordering operators.

The introduction of true total order semantics for `Comparable` means the default definitions of comparison operators can be derived from the compare operator alone.

```swift
// Derives a `<` operator for any `Comparable` type.
func < <T: Comparable>(l: T, r: T) -> Bool {
  return (l <=> r) == .ascending
}
func > <T: Comparable>(l: T, r: T) -> Bool {
  return r < l
}
func <= <T: Comparable>(l: T, r: T) -> Bool {
  return !(r < l)
}
func >= <T: Comparable>(l: T, r: T) -> Bool {
  return !(l < r)
}
```

In addition, `Foundation` code will now bridge `NSComparisonResult` to `Ordering`  allowing for a fluid, natural, and safe API.

### Impact on existing code

Existing `Equatable` types that define an equivalence relation with `==` will need to implement `areSame(_:_:)`  and should remove their existing implementation of `==` .  All other existing `Equatable`  types should implement an `areSame(_:_:)`  that provides an equivalence relation, or should drop their `Equatable` conformance.

Existing `Comparable` types that define a total ordering with `<` will need to implement `<=>`  and should remove their existing implementation of any comparison operators .  All other existing `Comparable`  types should implement `<=>`  that provides a total ordering, or should drop their `Comparable` conformance.

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

After

```swift
struct Date: Comparable {
  let year: Int
  let month: Int
  let day: Int
}

func <=>(lhs: Date, rhs: Date) -> Ordering {
  let yearResult = lhs.year <=> rhs.year
  guard case .equal = yearResult else {
    return yearResult
  }
  let monthResult = lhs.month <=> rhs.month
  guard case .equal = monthResult else {
    return monthResult
  }
  return lhs.day <=> rhs.day
}
```

### Alternatives considered

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