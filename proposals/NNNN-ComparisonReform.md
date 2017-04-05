# Comparison Reform

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Robert Widmann](https://github.com/codafi), [Jaden Geller](https://github.com/jadengeller), [Harlan Haskins](https://github.com/harlanhaskins), [Alexis Beingessner](https://github.com/Gankro), [Ben Cohen](https://github.com/airspeedswift)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is for changes that we believe should be made to the existing
comparison system by:

* Making FloatingPoint comparison context sensitive, so that its `Comparable`
  conformance provides a proper total ordering. 
* Introducing a new ternary-valued `compare(_ other: Self) -> ComparisonResult`
  method. 
* Removing unnecessary customization points from `Comparable`.

## Motivation

The motivation comes from several independent points:

1: The standard comparison operators have an intuitive meaning to programmers.
Swift encourages encoding that in an implementation of `Comparable` that
respects the rules of a [total
order](https://en.wikipedia.org/wiki/Total_order). The standard library takes
advantage of these rules to provide consistent implementations for sorting and
searching generic collections of `Comparable` types.

Not all types behave so well in this framework, unfortunately. There are cases
where the semantics of a total order cannot apply while still maintaining the
traditional definition of “comparison” for these types. Take, for example,
sorting an array of `Float`s. Today, `Float`'s instance of `Comparable` follows
IEEE-754 and returns `false` for all comparisons of `NaN`. In order to sort
this array, `NaN` s are considered outside the domain of `<`, and the order of
a sorted array containing them is unspecified. Similarly, a Dictionary keyed
off floats can leak entries and memory.

2: Generic algorithms in the Swift Standard Library that make use of the
current `Comparable` protocol may have to make extra comparisons to determine
the ordering of values when `<`, `==`, and `>` should have different
behaviours. Having a central operation to return complete ordering information
should provide a speedup for these operations.

3: The existing comparison operators don't "generalize" well. There's no clean
way to add a third or fourth argument to `<` to ask for non-default semantics.
An example where this would be desirable would be specifying the locale or
case-sensitivity when comparing Strings.

4: `Comparable` is over-engineered in the customization points it provides: to
our knowledge, there's no good reason to ever override `>=`, `>`, or `<=`. Each
customization point bloats vtables and mandates additional dynamic dispatch.

5: When quickly writing a `Comparable` type, it is easier to implement a single
ternary statement than to separately implement `==` and `<`.

## Proposed solution

### `ComparisonResult`

Foundation's ComparisonResult type will be mapped into Swift as 

```swift
@objc public enum ComparisonResult : Int {
  case orderedAscending = -1
  case orderedSame = 0
  case orderedDescending = 1
}
```


### `Comparable`

Comparable will be changed to have a new ternary comparison method: `compare(_
other: Self) -> ComparisonResult`. `x.compare(y)` specifies where to place x
relative to y. So if it yields `.orderedAscending`, then x comes before y. This
will be considered the new "main" dispatch point of Comparable that
implementors should provide.

Most code will continue to use `<` or `==`, as it will be optimal for their
purposes. However code that needs to make a three-way branch on comparison can
use the potentially more efficient `compare`. Note that `compare` is only
expected to be more efficient in this specific case. If a two-way branch is all
that's being done, `<` will be more efficient in many cases (if only because
it's easier for the optimizer).

For backwards compatibility reasons, `compare` will have a default
implementation defined in terms of `<`, but to enable only using `compare`,
`<` and `==` will also have default implementations in terms of `compare`.

The compiler will verify that either `compare`, or `<` and `==`, are provided
by every type that claims to conform to `Comparable`. This will be done in some
unspecified way unavailable outside the standard library (it can be made
available to in the future, but that's an unnecessary distraction for this
proposal).

Types that wish to provide comparison "variants" can do so naturally by adding
`compare` methods with additional arguments. e.g. `String.compare(_ other: Self,
in: Locale) -> ComparisonResult`. These have no language-level connection to
`Comparable`, but are still syntactically connected, implying the same total
order semantics. This makes them easier to discover, learn, and migrate to.

To reduce bloat, the operators `<=`, `>=`, and `>` will be removed from the set
of requirements that the `Comparable` protocol declares. These operators will
however continue to exist with the current default implementations.

### `FloatingPoint`

No changes will be made to the `FloatingPoint` protocol itself. Instead, new
extensions will be added to it to change the behaviour of comparison.

The new behaviour centers around the fact that `compare(_: Self) ->
ComparisonResult` will provide a total ordering that's consistent with Level 2
in the IEEE 754 (2008) spec. This is mostly the same as the standard (Level 1)
IEEE ordering, except:

  * `-0 < +0`
  * `NaN == NaN`
  * `NaN > +Inf` (an arbitrary choice, NaN can be placed anywhere in the number line)

Level 2's distinguishing of `-0` and `+0` is a bit strange, but is consistent
with Equatable's Substitutability requirement. `-0` and `+0` have different
behaviours: `1/-0 = -Inf` while `1/+0 = +Inf`. The main problem this can lead
to is that a keyed collection may have two "0" entries. In practice this
probably won't be a problem because it's fairly difficult for the same
algorithm to produce both `-0` and `+0`. Any algorithm that does is also
probably concerned with the fact that `1.0E-128` and `2.0E-128` are considered
distinct values.

Note: IEEE specifies several other potential total orderings: level 3, level 4,
and the totalOrder predicate. For our purposes, these orderings are too
aggressive in distinguishing values that are semantically equivalent in Swift.
For most cases, the relevant issue is that they distinguish different encodings
of NaN. For more exotic encodings that don't guarantee normalization, these
predicates also consider `10.0e0 < 1.0e1` to be true. An example where this can
occur is *IEEE-754 decimal coded floating point*, which FloatingPoint is
intended to support.

We will then make the comparison operators (`<`, `<=`, `==`, `!=`, `>=`, `>`)
dispatch to one of `compare(_:)` or FloatingPoint's IEEE comparison methods
(`isLess`, `isEqual`, `isLessThanOrEqualTo`) based on the context.

* If the context knows the type is FloatingPoint, then level 1 ordering will be
  used.
* If the context only knows the type is Comparable or Equatable, then level 2
  ordering will be used.

This results in code that is explicitly designed to work with FloatingPoint
types getting the expected IEEE behaviour, while code that is only designed to
work with Comparable types (e.g. `sort` and `Dictionary`) gets more reasonable
total ordering behaviour.

To clarify: `Dictionary` and `sort` won't somehow detect that they're being
used with `FloatingPoint` types and use level 1 comparisons. Instead they will
unconditional use level 2 behaviour. For example:

```swift
let nan = 0.0/0.0

func printEqual<T: Equatable>(_ x: T, _ y: T) {
  print(x == y)
}

func printEqualFloats<T: FloatingPoint>(_ x: T, _ y: T) {
  print(x == y)
}

print(nan == nan)          // false, (concrete)
printEqual(nan, nan)       // true,  (generic Equatable but not FloatingPoint)
printEqualFloats(nan, nan) // false, (generic FloatingPoint)
```

If one wishes to have a method that works with all Equatable/Comparable types,
but uses level 1 semantics for FloatingPoint types, then they can simply
provide two identical implementations that differ only in the bounds:

```swift
let nan = 0.0/0.0

func printEqual<T: Equatable>(_ x: T, _ y: T) {
  print(x == y)
}

func printEqual<T: FloatingPoint>(_ x: T, _ y: T) {
  print(x == y)
}

printEqual(0, 0)           // true (integers use `<T: Equatable>` overload)
printEqual(nan, nan)       // false (floats use `<T: FloatingPoint>` overload)
```

As a result of this change, hashing of floats must be updated to make all NaNs
hash equally. -0 and +0 will also no longer be expected to hash equally.
(Although they might as an implementation detail -- equal values must hash the
same, unequal values *may* hash the same.)

### Misc Standard Library

Types that conform to `Comparable` should be audited for places where
implementing or using `Comparable` would be a win. This update can be done
incrementally, as the only potential impact should be performance. As an
example, a default implementation of `compare(_:)` for Array will likely be
suboptimal, performing two linear scans to determine the result in the
worst-case. (See the default implementation provided in the detailed design.)

Some free functions will have `<T: FloatingPoint>` overloads to better align
with IEEE-754 semantics. This will be addressed in a follow-up proposal.
(example: `min` and `max`)

## Detailed Design

The protocols will be changed as follows:

`ComparisonResult`, currently a type found in Foundation, will be sunk into the
Swift Standard Library:

```swift
@objc public enum ComparisonResult: Int, Equatable {
  case orderedAscending = -1
  case orderedSame = 0
  case orderedDescending = 1
}

public protocol Comparable: Equatable {
  func compare(_ other: Self) -> ComparisonResult

  static func < (lhs: Self, rhs: Self) -> Bool
}

extension Comparable {
  func compare(_ other: Self) -> ComparisonResult {
    if self == other {
      return .orderedSame
    } else if self < other {
      return .orderedAscending
    } else {
      return .orderedDescending
    }
  }
}

public func < <T: Comparable>(lhs: T, rhs: T) -> Bool {
  return lhs.compare(rhs) == .orderedAscending
}

// IEEE comparison operators (these implementations already exist in std)
extension FloatingPoint {
  public static func == (lhs: T, rhs: T) -> Bool {
    return lhs.isEqual(to: rhs)
  }

  public static func < (lhs: T, rhs: T) -> Bool {
    return lhs.isLess(than: rhs)
  }

  public static func <= (lhs: T, rhs: T) -> Bool {
    return lhs.isLessThanOrEqualTo(rhs)
  }

  public static func > (lhs: T, rhs: T) -> Bool {
    return rhs.isLess(than: lhs)
  }

  public static func >= (lhs: T, rhs: T) -> Bool {
    return rhs.isLessThanOrEqualTo(lhs)
  }
}


// Comparable comparison operators (provides a total ordering)
extension FloatingPoint {
  @_inline
  public func compare(_ other: Self) -> ComparisonResult {
    // Can potentially be implemented more efficiently -- this is just the clearest version
    if self.isLess(than: other) {
      return .orderedAscending
    } else if other.isLess(than: self) {
      return .orderedDescending
    } else {
      // Special cases

      // -0 < +0
      if self.isZero && other.isZero {
        // .plus == 0 and .minus == 1, so flip ordering to get - < +
        return (other.sign as Int).compare(self.sign as Int)
      }

      // NaN == NaN, NaN > +Inf
      if self.isNaN {
        if other.isNaN {
          return .orderedSame
        } else {
          return .orderedDescending
        }
      } else if other.isNaN {
        return .orderedAscending
      } 

      // Otherwise equality agrees with normal IEEE
      return .orderedSame
    }
  }

  @_implements(Equatable.==)
  public static func _comparableEqual(lhs: Self, rhs: Self) -> Bool {
    lhs.compare(rhs) == .orderedSame
  }

  @_implements(Comparable.<)
  public static func _comparableLessThan(lhs: Self, rhs: Self) -> Bool {
    lhs.compare(rhs) == .orderedDescending
  }
}
```

Note that this design mandates changes to the compiler:

* @_implements (or an equivalent mechanism) must be implemented to get the
  context-sensitive FloatingPoint behaviour.

* The compiler must verify that either == and <, or compare(_:) is overridden
  by every type that conforms to Comparable.


## Source compatibility

Users of `ComparisonResult` will be able to use it as normal once it becomes a
standard library type.

Existing implementors of `Comparable` will be unaffected, though they should
consider implementing the new `compare` method as the default implementation
may be suboptimal.

Consumers of `Comparable` will be unaffected, though they should consider
calling the `compare` method if it offers a performance advantage for their
particular algorithm.

Existing implementors of `FloatingPoint` should be unaffected -- they will
automatically get the new behaviour as long as they aren't manually
implementing the requirements of Equatable/Comparable.

Existing code that works with floats may break if it's relying on some code
bounded on `<T: Equatable/Comparable>`providing IEEE semantics. For most
algorithms, NaNs would essentially lead to unspecified behaviour, so the
primary concern is whether -0.0 == +0.0 matters.


## ABI stability 

This must be implemented before ABI stability is declared.

## Effect on API resilience

N/A

## Alternatives Considered


### Spaceship

Early versions of this proposal aimed to instead provide a `<=>` operator in
place of `compare`. The only reason we moved away from this was that it didn't
solve the problem that comparison didn't generalize.

Spaceship as an operator has a two concrete benefits over `compare` today:

* It can be passed to a higher-order function
* Tuples can implement it

In our opinion, these aren't serious problems, especially in the long term. 

Passing `<=>` as a higher order function basically allows types that aren't
Comparable, but do provide `<=>`, to be very ergonomically handled by
algorithms which take an optional ordering function. Types which provide the
comparable operators but don't conform to Comparable are only pervasive due to
the absence of conditional conformance. We shouldn't be designing our APIs
around the assumption that conditional conformance doesn't exist.

When conditional conformance is implemented, the only
should-be-comparable-but-aren't types that will remain are tuples, which we
should potentially have the compiler synthesize conformances for.

Similarly, it should one day be possible to extend tuples, although this is a
more "far future" matter. Until then, the `(T, T) -> Bool` predicate will
always also be available, and `<` can be used there with the only downside
being a potential performance hit.


### Just Leave Floats Alone

The fact that sorting floats leads to a mess, and storing floats can lead to
memory leaks and data loss isn't acceptable.

### Just Make Floats Only Have A Total Order

This was deemed too surprising for anyone familiar with floats from any other
language. It would also probably break a lot more code than this change will.


### Just Make Floats Not Comparable

Although floats are more subtle than integers, having places where integers
work but floats don't is a poor state of affairs. One should be able to sort an
array of floats and use floats as keys in data structures, even if the latter
is difficult to do correctly.

### PartialComparable

PartialComparable would essentially just be Comparable without any stated
ordering requirements, that Comparable extends to provide ordering
requirements. This would be a protocol that standard IEEE comparison could
satisfy, but in the absence of total ordering requirements, PartialComparable
is effectively useless. Either everyone would consume PartialComparable (to
accept floats) or Comparable (to have reasonable behaviour).

The Rust community adopted this strategy to little benefit. The Rust libs team
has frequently considered removing the distinction, but hasn't because doing it
backwards compatibly would be complicated. Also because merging the two would
just lead to the problems Swift has today.

### Different Names For `compare` and `ComparisonResult`

A few different variants for `ComparisonResult` and its variants were considered:

* Dropping the `ordered` part of `ComparisonResult`'s cases e.g. `.ascending`
* Naming of `ComparisonResult` as `SortOrder`
* `enum Ordering { case less, equal, greater }` ([as used by Rust](https://doc.rust-lang.org/std/cmp/enum.Ordering.html))
* Case values of `inOrder`, `same`, `outOfOrder`

The choice of case names is non-trivial because the enum shows up in different
contexts where different names makes more sense. Effectively, one needs to keep
in mind that the "default" sort order is ascending to map between the concept
of "before" and "less".

The before/after naming to provide the most intuitive model for custom sorts --
referring to `ascending` or `less` is confusing when trying to implement a
descending ordering. Similarly the inOrder/outOfOrder naming was too indirect
-- it's more natural to just say where to put the element. If the enum should
focus on the sorting case, calling it `SortOrder` would help to emphasize this
fact.

This proposal elects to leave the existing Foundation name in-place. The
primary motivation for this is that use of the `compare` function will be
relatively rare. It is expected that in most cases users will continue to make
use of `==` or `<`, returning boolean values (the main exception to this will
be in use of the parameterized `String` comparisons). As such, the source
compatibility consequences of introducing naming changes to an existing type
seems of insufficient benefit.

The method `compare(_:)` does not fully comport with the API naming guidelines.
However, it is firmly established with current usage in Objective-C APIs, will
be fairly rarely seen/used (users will usually prefer `<`, `==` etc), and
alternatives considered, for example `compared(to:)`, were not a significant
improvement.

### Add Overloads for `(T, T) -> ComparisonResult`

It would be slightly more ergonomic to work with ComparisonResult if existing
methods that took an ordering predicate also had an overload for `(T, T) ->
ComparisonResult`. As it stands, a case-insensitive sort must be written as
follows:

```swift
myStrings.sort { $0.compare(_ other: $1, case: .insensitive) == .orderedAscending }
```

With the overload, one could write:

```swift
myStrings.sort { $0.compare($1, case: .insensitive) }
```

we decided against providing these overloads because: 

* The existing algorithms in the standard library can't benefit from them (only binary comparisons).
* They bloat up the standard library (and any library which intends to match our API guidelines).
* They potentially introduce confusion over "which" comparison overload to use.

And because we can change our mind later without concern for source or ABI
stability, as these overloads would be additive.

## Future Work

This section covers some topics which were briefly considered, but were
identified as reasonable and possible to defer to future releases. Specifically
they should be backwards compatible to introduce even after ABI stability. Two
paths that are worth exploring:


### Ergonomic Generalized Comparison for Keyed Containers 

Can we make it ergonomic to use an (arbitrary) alternative comparison strategy
for a Dictionary or a BinaryTree? Should they be type-level Comparators, or
should those types always store a `(Key, Key) -> ComparisonResult` closure?

We can avoid answering this question because `Dictionary` is expected to keep a
relatively opaque (resilient) ABI for the foreseeable future, as many
interesting optimizations will change its internal layout. Although if the
answer is type-level, then Default Generic Parameters must be accepted to
proceed down this path.


### ComparisonResult Conveniences

There are a few conveniences we could consider providing to make
ComparisonResult more ergonomic to manipulate. Such as:

```swift
// A way to combine orderings
func ComparisonResult.breakingTiesWith(_ order: () -> ComparisonResult) -> ComparisonResult

array.sort {
  $0.x.compare($0.y)
  .breakingTiesWith { $0.y.compare($1.y) }
  == .orderedAscending 
}
```

and

```swift
var inverted: ComparisonResult

// A perhaps more "clear" way to express reversing order than `y.compared(to: x)`
x.compare(y).inverted
```

But these can all be added later once everyone has had a chance to use them.



