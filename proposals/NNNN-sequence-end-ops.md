# Rationalizing Sequence end-operation names

* Proposal: [SE-NNNN](NNNN-sequence-end-op.md)
* Author: [Brent Royal-Gordon](https://github.com/brentdax)
* Status: **Awaiting Review**
* Review manager: TBD

## Introduction

Sequence and Collection offer many special operations which access or 
manipulate its first or last elements, but they are plagued by 
inconsistent naming which can make it difficult to find inverses or 
remember what the standard library offers. I propose that we standardize 
these names so they follow consistent, predictable patterns.

Swift-evolution thread: [[Draft] Rationalizing Sequence end-operation names](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21449/focus=23013)

### Scope

**This proposal is not intended to add or remove any functionality**; 
it merely renames and redesigns existing operations. **Adding new 
operations is out of scope for this proposal** unless it's incidental 
to the new designs.

Nonetheless, I *do* want the new designs to support adding more 
operations in the future. The names I've chosen are informed by some of 
the speculative APIs discussed in "Future directions", although I think 
they are perfectly sensible names even if nothing else changes.

## Motivation

The `Sequence` and `Collection` protocols offer a wide variety of APIs 
which are defined to operate on, or from, one end of the sequence:

|                                  | Get                           | Index                        | Exclude                     | Remove (1)       | Pop (1)      | Equate (2)                                     |
| -------------------------------- | ----------------------------- | ---------------------------- | --------------------------- | ---------------- | ------------ | ---------------------------------------------- |
| **Fixed Size**                   |
| First 1                          | C.first                       | -                            | S.dropFirst()               | C.removeFirst()  | C.popFirst() | -                                              |
| Last 1                           | C.last                        | -                            | S.dropLast()                | C.removeLast()   | C.popLast()  | -                                              |
| First (n: Int)                   | S.prefix(3)                   | -                            | S.dropFirst(3)              | C.removeFirst(3) | -            | S.starts(with:&nbsp;[x,y,z])                   |
| &nbsp;&nbsp;...with closure      | S.prefix(while:&nbsp;isPrime) | -                            | S.drop(while:&nbsp;isPrime) | -                | -            | S.starts(with:&nbsp;[x,y,z],&nbsp;by:&nbsp;==) |
| Last (n: Int)                    | S.suffix(3)                   | -                            | S.dropLast(3)               | C.removeLast(3)  | -            | -                                              |
| &nbsp;&nbsp;...with closure      | -                             | -                            | -                           | -                | -            | -                                              |
| **Searching From End**           |
| First&nbsp;matching&nbsp;element | -                             | C.index(of:&nbsp;x)          | -                           | -                | -            | -                                              |
| &nbsp;&nbsp;...with closure      | S.first(where:&nbsp;isPrime)  | C.index(where:&nbsp;isPrime) | -                           | -                | -            | -                                              |
| Last matching element            | -                             | -                            | -                           | -                | -            | -                                              |
| &nbsp;&nbsp;...with closure      | -                             | -                            | -                           | -                | -            | -                                              |
| **Based on Index**               |
| startIndex ..< (i: Index)        | C.prefix(upTo:&nbsp;i)        | -                            | -                           | -                | -            | -                                              |
| startIndex ... (i: Index)        | C.prefix(through:&nbsp;i)     | -                            | -                           | -                | -            | -                                              |
| (i: Index) ..< endIndex          | C.suffix(from:&nbsp;i)        | -                            | -                           | -                | -            | -                                              |

> I have included several blank rows for operands which fit the APIs'
> patterns, even if they don't happen to have any operations currently.
> 
> **Type abbreviations:**
> 
> * S = Sequence
> * C = Collection (or a sub-protocol like BidirectionalCollection)
> 
> **Notes:**
> 
> 1. `remove` and `pop` both mutate the array to delete the indicated 
>    element(s), but `remove` assumes as a precondition that the 
>    indicated elements exist, while `pop` checks whether or not they 
>    exist.
>
> 2. `String` and `NSString` have bespoke versions of *first n* and 
>    *last n* Equate operations, in the form of their `hasPrefix` and 
>    `hasSuffix` methods.

Leaving aside the question of whether any gaps in these tables ought to 
be filled, I see a number of issues with existing terminology.

### Inconsistent use of `prefix` and `suffix`

Some APIs which operate on a variable number of elements anchored at 
one end or the other use the terms `prefix` or `suffix`:

* `Sequence.prefix(_:)` and `Sequence.suffix(_:)`
* `Sequence.prefix(while:)`
* `String.hasPrefix(_:)` and `String.hasSuffix(_:)`

Others, however, use `first` or `last`:

* `Sequence.dropFirst(_:)` and `Sequence.dropLast(_:)`
* `Sequence.removeFirst(_:)` and `Sequence.removeLast(_:)`

Still others use neither:

* `Sequence.starts(with:)`
* `Sequence.drop(while:)`

These methods are all closely related, but because of this inconsistent 
terminology, they fail to form predictable method families.

### `first` has multiple meanings

The word `first` can mean three different things in these APIs:

1. Just the very first element of the sequence.

2. A subsequence of elements anchored at the beginning of the sequence, 
   as mentioned in the last point.

3. The first element encountered in the sequence which matches a given 
   criterion when walking from the beginning of the sequence towards the 
   end.

It would be nice to have more clarity here—particularly around #2, which 
implies different return value behavior.

### `drop` is misleading and scary

In a Swift context, I believe the `drop` methods are actively confusing:

* `drop` does not have the -ing or -ed suffix normally used for a 
  nonmutating method.

* `drop` has strong associations with destructive operations; it's the 
  term used, for instance, for deleting whole tables in SQL. Even 
  `dropping` would probably sound more like a mutating operation than 
  alternatives.

* As previously mentioned, the use of `dropFirst` and `dropLast` for 
  single-drop operations and multiple-drop operations breaks up method 
  families.

`drop`, `dropFirst`, and `dropLast` are terms of art, so we allow them 
a certain amount of leeway. However, I believe the `drop` functions 
go well beyond what we should permit. They are relatively 
uncommon operations, associated primarily with functional languages 
rather than mainstream object-oriented or imperative languages, and 
their violation of the normal Swift naming guidelines is especially 
misleading.

The term-of-art exception is not a suicide pact; it is meant to aid 
understanding by importing common terminology, not bind us to follow 
every decision made by any language that came before us. In this case, 
I think we should ignore precedent and forge our own path.

### Unstated direction of operation

Several APIs could theoretically be implemented by working from either 
end of the sequence, and would return different results depending on 
the direction, but do not indicate the direction in their names:

* `Sequence.drop(while:)`
* `Collection.index(of:)`

Adding a direction to these APIs would make their behavior clearer and 
permit us to offer opposite-end equivalents in the future. (Unmerged 
[swift-evolution pull request 329](https://github.com/apple/swift-evolution/pull/329) 
would add `lastIndex` methods.)

### Operations taking an index are really slicing

`prefix(upTo:)`, `prefix(through:)`, and `suffix(from:)` at first 
appear to belong to the same family as the other `prefix` and `suffix`
methods, but deeper examination reveals otherwise. They are the only 
operations which take indices, and they don't cleanly extend to the 
other operations which belong to these families. (For instance, it 
would not make sense to add a `dropPrefix(upTo:)` method; it would be 
equivalent to `suffix(from:)`.)

Also, on `Int`-indexed collections like `Array`, `prefix(_:)` and 
`prefix(upTo:)` are identical, but there is little relationship between 
`suffix(_:)` and `suffix(from:)`, which is confusing.

`suffix(from:)` is a particularly severe source of confusion. The other 
`suffix` APIs all have parameters relative to the *end* of the 
collection, but `suffix(from:)`'s index is still relative to the 
*beginning* of the array. This is obvious if you think deeply about the 
meaning of an index, but we don't really want to force our users to 
stare at a strange API until they have an epiphany.

I believe these operations have much more in common with slicing a 
collection using a range, and that reimagining them as slicing APIs 
will be more fruitful.

### Why does it matter?

Many of these APIs are only occasionally necessary, so it's important 
that they be easy to find when needed and easy to understand when 
read. If you know that `prefix(10)` will get the first ten elements but 
don't know what its inverse is, you will probably not guess that it's 
`dropFirst(10)`. The confusing, conflicting names in these APIs are a 
barrier to users adopting them where appropriate.

## Proposed solution

We sever the index-taking APIs from the others, forming two separate 
families, which I will call the "Sequence-end operations" and the 
"index-based operations". We then consider and redesign them along 
separate lines.

### Sequence-end operations

Each of these APIs should be renamed to use a directional word based on 
its row in the table:

| Operand                          | Directional word   |
| -------------------------------- | ------------------ |
| **Fixed Size**                   |
| First 1                          | first              |
| Last 1                           | last               |
| First (n: Int)                   | prefix             |
| &nbsp;&nbsp;...with closure      | prefix             |
| Last (n: Int)                    | suffix             |
| &nbsp;&nbsp;...with closure      | suffix             |
| **Searching From End**           |
| First&nbsp;matching&nbsp;element | first              |
| &nbsp;&nbsp;...with closure      | first              |
| Last matching element            | last               |
| &nbsp;&nbsp;...with closure      | last               |

To accomplish this, `starts(with:)` should be renamed to 
`hasPrefix(_:)`, and other APIs should have directional words replaced 
or added as appropriate.

Additionally, the word `drop` in the "Exclude" APIs should be replaced 
with `removing`. These operations omit the same elements which the 
`remove` operations delete, so even though the types are not always the 
same (`removing` returns `SubSequence`, not `Self`), I think they are 
similar enough to deserve to be treated as nonmutating forms.

These changes yield (altered names **bold**):

|                                  | Get                           | Index                                 | Exclude                                   | Remove (1)            | Pop (1)      | Equate (2)                                 |
| -------------------------------- | ----------------------------- | ------------------------------------- | ----------------------------------------- | --------------------- | ------------ | ------------------------------------------ |
| **Fixed Size**                   |
| First 1                          | C.first                       | -                                     | **S.removingFirst()**                     | C.removeFirst()       | C.popFirst() | -                                          |
| Last 1                           | C.last                        | -                                     | **S.removingLast()**                      | C.removeLast()        | C.popLast()  | -                                          |
| First (n: Int)                   | S.prefix(3)                   | -                                     | **S.removingPrefix(3)**                   | **C.removePrefix(3)** | -            | **S.hasPrefix([x,y,z])**                   |
| &nbsp;&nbsp;...with closure      | S.prefix(while:&nbsp;isPrime) | -                                     | **S.removingPrefix(while:&nbsp;isPrime)** | -                     | -            | **S.hasPrefix([x,y,z],&nbsp;by:&nbsp;==)** |
| Last (n: Int)                    | S.suffix(3)                   | -                                     | **S.removingSuffix(3)**                   | **C.removeSuffix(3)** | -            | -                                          |
| &nbsp;&nbsp;...with closure      | -                             | -                                     | -                                         | -                     | -            | -                                          |
| **Searching From End**           |
| First&nbsp;matching&nbsp;element | -                             | **C.firstIndex(of:&nbsp;x)**          | -                                         | -                     | -            | -                                          |
| &nbsp;&nbsp;...with closure      | S.first(where:&nbsp;isPrime)  | **C.firstIndex(where:&nbsp;isPrime)** | -                                         | -                     | -            | -                                          |
| Last matching element            | -                             | -                                     | -                                         | -                     | -            | -                                          |
| &nbsp;&nbsp;...with closure      | -                             | -                                     | -                                         | -                     | -            | -                                          |

### Index-based operations

Because these APIs look up elements based on their indices, I believe 
these operations should be exposed as subscripts, and ideally should 
look like other slicing operations.

The syntax I recommend is:

```swift
let head = people[..<i]
let tail = people[i..<]
let rearrangedPeople = tail + head
```

<!-- Comment to make my editor happy -->

I prefer this option because it offers an elegant syntax immediately 
recognizable as a form of slicing, and provides a straightforward way 
for a future version of Swift to extend other `Range`-handling 
`Collection` operations, like `replaceSubrange(_:with:)` and 
`removeSubrange(_:)`, to handle subranges bound by the ends of the 
`Collection`.

The operators would construct instances of a new pair of types, 
`IncompleteRange` (for `..<`) and `IncompleteClosedRange` (for `...`), 
and `Collection` would include new subscripts taking these types. These 
would probably have default implementations which constructed an 
equivalent `Range` or `ClosedRange` using `startIndex` and `endIndex`, 
then passed the resulting range through to the existing subscripts.

There should also be infix `..<` and `...` operators which take optional 
bounds; this allows for cases where a bound may be specified, or may be 
left to the default.

## Detailed design

### Sequence-end operations

The following methods should be renamed as follows wherever they appear 
in the standard library. These are simple textual substitutions; we 
propose no changes whatsoever to types, parameter interpretations, or 
other semantics.

| Old method                                        | New method                                              |
| ------------------------------------------------- | ------------------------------------------------------- |
| `dropFirst() -> SubSequence`                      | `removingFirst() -> SubSequence`                        |
| `dropLast() -> SubSequence`                       | `removingLast() -> SubSequence`                         |
| `dropFirst(_ n: Int) -> SubSequence`              | `removingPrefix(_ n: Int) -> SubSequence`               |
| `drop(@noescape while predicate: (Iterator.Element) throws -> Bool) rethrows -> SubSequence` | `removingPrefix(@noescape while predicate: (Iterator.Element) throws -> Bool) rethrows -> SubSequence` |
| `dropLast(_ n: Int) -> SubSequence`               | `removingSuffix(_ n: Int) -> SubSequence`               |
| `removeFirst(_ n: Int)`                           | `removePrefix(_ n: Int)`                                |
| `removeLast(_ n: Int)`                            | `removeSuffix(_ n: Int)`                                |
| `starts<PossiblePrefix: Sequence>(with possiblePrefix: PossiblePrefix) -> Bool where ...` | `hasPrefix<PossiblePrefix: Sequence>(_ possiblePrefix: PossiblePrefix) -> Bool where ...` |
| `starts<PossiblePrefix : Sequence>(with possiblePrefix: PossiblePrefix, by areEquivalent: @noescape (Iterator.Element, Iterator.Element) throws -> Bool) rethrows -> Bool where ...` | `hasPrefix<PossiblePrefix : Sequence>(_ possiblePrefix: PossiblePrefix, by areEquivalent: @noescape (Iterator.Element, Iterator.Element) throws -> Bool) rethrows -> Bool where ...` |
| `index(of element: Iterator.Element) -> Index?`   | `firstIndex(of element: Iterator.Element) -> Index?` |
| `index(where predicate: @noescape (Iterator.Element) throws -> Bool) rethrows -> Index?` | `firstIndex(where predicate: @noescape (Iterator.Element) throws -> Bool) rethrows -> Index?` |

### Index-based operations

We should introduce a pair of new types, `IncompleteRange` and 
`IncompleteClosedRange`. Each should be used with a pair of new 
operators, prefix and suffix versions of `..<` and `...`, as well 
as new `Optional`-taking versions of the infix operators. An 
extension on `Collection` should include new subscripts which 
call through to the equivalent `Range` or `ClosedRange`-based 
subscripts.

An illustrative interface for `IncompleteRange` is shown below; 
`IncompleteClosedRange` would be similar. A full prototype is available 
[on GitHub](https://github.com/brentdax/swift/tree/incomplete-range).

```swift
/// A `Range` which may not have all of its bounds specified.
/// The `IncompleteRange` can be completed by providing a 
/// `Range` or `CountableRange` from which it can retrieve 
/// default upper and lower bounds.
public struct IncompleteRange<Bound : Comparable> {
  /// The lowest value within the range. 
  /// If `nil`, completing the range will adopt the default value's 
  /// `lowerBound`.
  public let lowerBound: Bound?
  /// The value just above the highest value within the range.
  /// If `nil`, completing the range will adopt the default value's 
  /// `upperBound`.
  public let upperBound: Bound?
}

extension IncompleteRange {
  /// Returns a `Range` with the same `upperBound` 
  /// and `lowerBound` as the current instance. `nil` bounds are 
  /// filled in from `defaultBounds`.
  /// 
  /// This method does not check whether `lowerBound` and `upperBound` 
  /// lie within `defaultBounds`. 
  public func completed(by defaultBounds: Range<Bound>) -> Range<Bound>
  
  /// Returns a `Range` with the same `upperBound` 
  /// and `lowerBound` as the current instance. `nil` bounds are 
  /// filled in from `defaultBounds`.
  /// 
  /// This method does not check whether `lowerBound` and `upperBound` 
  /// lie within `defaultBounds`. 
  /// Nor does it check whether the resulting `lowerBound` is below 
  /// its `upperBound`.
  public func completed(byUnchecked defaultBounds: Range<Bound>) -> Range<Bound>
}

extension IncompleteRange where
    Bound : Strideable,
    Bound.Stride : SignedInteger {
  /// Returns a `CountableRange` with the same `upperBound` 
  /// and `lowerBound` as the current instance. `nil` bounds are 
  /// filled in from `defaultBounds`.
  /// 
  /// This method does not check whether `lowerBound` and `upperBound` 
  /// lie within `defaultBounds`. 
  public func completed(by defaultBounds: CountableRange<Bound>) -> CountableRange<Bound>
  
  /// Returns a `CountableRange` with the same `upperBound` 
  /// and `lowerBound` as the current instance. `nil` bounds are 
  /// filled in from `defaultBounds`.
  /// 
  /// This method does not check whether `lowerBound` and `upperBound` 
  /// lie within `defaultBounds`. 
  /// Nor does it check whether the resulting `lowerBound` is below 
  /// its `upperBound`.
  public func completed(byUnchecked defaultBounds: CountableRange<Bound>) -> CountableRange<Bound>
}

/// Constructs an `IncompleteRange` with the provided upper 
/// bound and an unknown lower bound.
public prefix func ..< <Bound: Comparable>(upperBound: Bound) -> IncompleteRange<Bound>

/// Constructs an `IncompleteRange` with the provided lower 
/// bound and an unknown upper bound.
public postfix func ..< <Bound: Comparable>(lowerBound: Bound) -> IncompleteRange<Bound>

/// Constructs an `IncompleteRange` with the provided upper 
/// and lower bounds. Either or both may be `nil`, in which case the 
/// bound will be provided when the `IncompleteRange` is 
/// completed.
public func ..< <Bound: Comparable>(lowerBound: Bound?, upperBound: Bound?) -> IncompleteRange<Bound>

// Note: The documentation below is based on the generated docs for 
// existing slicing subscripts, with one line added to the `bounds` 
// parameter coverage. I think these docs could perhaps use some 
// revisiting as a whole.

extension Indexable {
  /// Accesses a contiguous subrange of the collection's elements.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  /// This example demonstrates getting a slice of an array of strings, finding
  /// the index of one of the strings in the slice, and then using that index
  /// in the original array.
  ///
  ///     let streets = ["Adams", "Bryant", "Channing", "Douglas", "Evarts"]
  ///     let streetsSlice = streets[2 ..< streets.endIndex]
  ///     print(streetsSlice)
  ///     // Prints "["Channing", "Douglas", "Evarts"]"
  ///
  ///     let index = streetsSlice.index(of: "Evarts")    // 4
  ///     print(streets[index!])
  ///     // Prints "Evarts"
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///   the range must be valid indices of the collection.
  ///   The bounds will be completed using `startIndex` and `endIndex`.
  public subscript(bounds: IncompleteRange<Index>) -> SubSequence {
    get {
      return self[
        bounds.completed(by: Range(uncheckedBounds: (startIndex, endIndex)))
      ]
    }
  }
}

extension MutableIndexable {
  /// Accesses a contiguous subrange of the collection's elements.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  /// This example demonstrates getting a slice of an array of strings, finding
  /// the index of one of the strings in the slice, and then using that index
  /// in the original array.
  ///
  ///     let streets = ["Adams", "Bryant", "Channing", "Douglas", "Evarts"]
  ///     let streetsSlice = streets[2 ..< streets.endIndex]
  ///     print(streetsSlice)
  ///     // Prints "["Channing", "Douglas", "Evarts"]"
  ///
  ///     let index = streetsSlice.index(of: "Evarts")    // 4
  ///     streets[index!] = "Eustace"
  ///     print(streets[index!])
  ///     // Prints "Eustace"
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///   the range must be valid indices of the collection.
  ///   The bounds will be completed using `startIndex` and `endIndex`.
  public subscript(bounds: IncompleteRange<Index>) -> SubSequence {
    get {
      return self[
        bounds.completed(by: Range(uncheckedBounds: (startIndex, endIndex)))
      ]
    }
    set {
      self[
        bounds.completed(by: Range(uncheckedBounds: (startIndex, endIndex)))
      ] = newValue
    }
  }
}
```

## Impact on existing code

Obviously, any code using these APIs under their old names or designs 
would have to be transitioned to the new names and designs.

The sequence-end operations would be by far the simplest to handle; 
these are simple renamings and could be handed by 
`@available(renamed:)` and migration support. The only complication 
is that some overloads have transitioned to a new base name, while 
others have stayed with the old one, but I suspect the migrator is up 
to this task.

The preferred option for index-based operations is more difficult to 
migrate. The patterns would be roughly:

```swift
collection.prefix(upTo: i)    => collection[..<i]
collection.prefix(through: i) => collection[...i]
collection.suffix(from: i)    => collection[i..<]
```

A custom fix-it would be ideal, but is probably not absolutely 
necessary here; an `@available(message:)` would do in a pinch. 
Presumably this would have to be a special case in the migrator as 
well.

## Alternatives considered

#### `skipping` instead of `removing`

If the type differences are seen as disqualifying `removing` as a 
replacement for `drop`, I suggest using `skipping` instead.

There are, of course, *many* possible alternatives to `skipping`; this 
is almost a perfect subject for bikeshedding. I've chosen `skipping` 
because:

1. It is not an uncommon word, unlike (say) `omitting`. This means 
   non-native English speakers and schoolchildren are more likely to 
   recognize it.

2. It is an -ing verb, unlike (say) `without`. This makes it fit common 
   Swift naming patterns more closely.

3. It does not imply danger, unlike (say) `dropping`, nor some sort of 
   ongoing process, unlike (say) `ignoring`. This makes its behavior 
   more obvious.

If you want to suggest an alternative on swift-evolution, please do not 
merely mention a synonym; rather, explain *why* it is an improvement on 
either these axes or other ones. (I would be particularly interested in 
names other than `removing` which draw an analogy to something else in 
Swift.)

#### `collection[to/through/from:]` instead of `IncompleteRange`

Rather than add new types and operators to replace 
`prefix(upTo/through:)` and `suffix(from:)`, we could merely transform 
these methods into subscripts with parameter labels. This would be a 
simpler design, but these terms have proven imperfect in the `stride` 
calls, and labeled subscripts are rare (actually, I believe they're 
unprecedented in the standard library).

#### `longestPrefix(where:)` instead of `prefix(while:)`

The name `prefix(while:)` isn't perfect; it seems to imply more state 
than is really involved. (There *is* a stateful loop, but it's 
contained within the method.) A name like `longestPrefix(where:)` might 
read better and avoid this implication, but I think it's important that 
`prefix(_:)` and `prefix(while:)` be given parallel names, and 
`longestPrefix(3)` doesn't make much sense.

#### `RangeExpression` protocol

With this addition, slicing uses as many as six overloads to handle 
different range types:

1. `Range`
2. `CountableRange`
3. `IncompleteRange`
4. `ClosedRange`
5. `CountableClosedRange`
6. `IncompleteClosedRange`

We could introduce a protocol which allows us to convert any of these 
other range types to a plain `Range`:

```swift
protocol RangeExpression {
  associatedtype Bound : Comparable
  func relative<C: Collection where C.Index == Bound>(to c: C) -> Range<Bound>
}
```

This would allow us to reduce our overload set from six to two (one for 
`Range`, the other for other `RangeExpression`s). However, doing this 
would require support for generic subscripts, which Swift 3 doesn't 
support.

### Other alternatives

* Rather than using `first` and `last` for the "First matching" and 
  "Last matching" categories, we could use a distinct term. These 
  methods have different performance characteristics than the others, 
  and modeling that might be helpful. However, it's difficult to find 
  a good term—an earlier version of this proposal used `earliest` and 
  `latest`, which don't read perfectly—and the level of confusion is 
  pretty low.

* I considered using `first` and `last` as the basis for both 
  single-element and multiple-element operations (such that `prefix(3)` 
  would become `first(3)`, etc.), but:
  
  1. These seemed like distinct functionalities, particularly since 
     their types are different.
  
  2. I'm not comfortable with heavily overloading a property with a 
     bunch of methods, and didn't want to make `first` and `last` into 
	 methods.
  
  3. Most APIs work fine, but `hasFirst(_:)` is atrocious, and I see 
     no better alternative which includes the word `first`.

* I considered moving `first` and `last` to `Sequence` and possibly 
  making them methods, but my understanding is that the core team has 
  considered and rejected this approach in the past.

* I considered moving `removingFirst` and `removingLast` to Collection 
  and making them properties, to match `first` and `last`, but this 
  seemed like the sort of foolish consistency that Ralph Waldo Emerson 
  warned of.

## Future directions

**Note**: The rest of this proposal is *highly* speculative and there's 
probably no need to read further.

### Other Sequence API cleanups

#### Seriously source-breaking

* There is an ongoing discussion about which, if any, of `map`, 
  `flatMap`, `filter`, and `reduce` ought to be renamed to more closely 
  match Swift naming conventions. There is also discussion about 
  relabeling many closure parameters.
  
  The "Future directions" section below suggests `every(where:)` as an 
  alternative to `filter` which could be extended in ways compatible 
  with this proposal.

#### Significantly source-breaking

* The `removeSubrange(_:)` and `replaceSubrange(_:with:)` APIs are 
  rather oddly named. They might be better renamed to, for instance, 
  `remove(in:)` and `replace(in:with:)`.

* It is not clear how important `removingFirst()` and `removingLast()` 
  actually are, given that they're exactly equivalent to 
  `removingPrefix(1)` and `removingSuffix(1)`, and their corresponding 
  "get" members are on `Collection` instead of `Sequence`. They could 
  be removed.

#### Slightly source-breaking

* `removeFirst/Last()` and `popFirst/Last()` are very nearly redundant; 
  their only difference is that the `remove` methods have a 
  non-`Optional` return type and require the collection not be empty, 
  while the `pop` methods have an `Optional` return type and return 
  `nil` if it's empty.
  
  These operations could be merged, with the `remove` operations taking 
  on the preconditions of the current `pop` operations; additionally, 
  `removePrefix(_:)` and `removeSuffix(_:)` could drop their equivalent 
  preconditions requiring that the elements being removed exist. These 
  changes would simplify the standard library and make these methods 
  more closely parallel the equivalent `removing` methods, which do 
  not have similar preconditions.
  
  Performance-critical code which wants to avoid the checks necessary 
  to remove these preconditions could switch to `remove(at:)` and 
  `removeSubrange(_:)`, which would continue to reject invalid indices.

### Adding sequence and collection operations

This exercise in renaming suggests all sorts of other APIs we might 
add, and a few we might rename.

In general, I have not attempted to carefully scrutinize the usefulness 
of each of these APIs; instead, I have merely listed the ones which I 
can imagine some kind of use for. The main exception is the "Pop" 
operation; I can imagine several different, and rather incompatible, 
ways to extend it, and I'm not going to take the time to sort out my 
thoughts merely to write a "Future directions" section.

#### Filling in the sequence-end API table

The gaps in the table suggest a number of APIs we could offer in the 
future. Here, I have filled in all options which are at least coherent:

|                                  | Get                  | Index                     | Exclude                        | Remove (1)                   | Pop (1)      | Equate (2)              |
| -------------------------------- | -------------------- | ------------------------- | ------------------------------ | ---------------------------- | ------------ | ----------------------- |
| **Fixed Size**                   |                                                                                                                                                          
| First 1                          | C.first              | **C.firstIndex**          | S.removingFirst()              | C.removeFirst()              | C.popFirst() | -                       |
| Last 1                           | C.last               | **C.lastIndex**           | S.removingLast()               | C.removeLast()               | C.popLast()  | -                       |
| First (n: Int)                   | S.prefix(\_:)        | **C.prefixIndex(\_:)**    | S.removingPrefix(\_:)          | C.removePrefix(\_:)          | -            | S.hasPrefix(\_:)        |
| &nbsp;&nbsp;...with closure      | S.prefix(while:)     | **C.prefixIndex(while:)** | S.removingPrefix(while:)       | **C.removePrefix(while:)**   | -            | S.hasPrefix(\_:by:)     |
| Last (n: Int)                    | S.suffix(\_:)        | **C.suffixIndex(\_:)**    | S.removingSuffix(\_:)          | C.removeSuffix(\_:)          | -            | **S.hasSuffix(\_:)**    |
| &nbsp;&nbsp;...with closure      | **S.suffix(while:)** | **C.suffixIndex(while:)** | **S.removingSuffix(while:)**   | **C.removeSuffix(while:)**   | -            | **S.hasSuffix(\_:by:)** |
| **Searching From End**           |
| First&nbsp;matching&nbsp;element | **S.first(\_:)**     | C.firstIndex(of:)         | **S.removingFirst(\_:)**       | **C.removeFirst(\_:)**       | -            | -                       |
| &nbsp;&nbsp;...with closure      | S.first(where:)      | C.firstIndex(where:)      | **S.removingFirst(where:)**    | **C.removeFirst(where:)**    | -            | -                       |
| Last matching element            | **S.last(\_:)**      | **C.lastIndex(of:)**      | **S.removingLast(\_:)**        | **C.removeLast(\_:)**        | -            | -                       |
| &nbsp;&nbsp;...with closure      | **S.last(where:)**   | **C.lastIndex(where:)**   | **S.removingLast(where:)**     | **C.removeLast(where:)**     | -            | -                       |

To explain a few entries which might not be immediately obvious: 
`firstIndex` and `lastIndex` would be `nil` if the collection is empty, 
and `lastIndex` would be the index before `endIndex`. `prefixIndex` 
would return the last index of the prefix, and `suffixIndex` would 
return the first index of the suffix; alternatively, these could be 
named with `Indices` and return ranges. `first(_:)` and `last(_:)` 
would return the first and last element equal to the provided value; on 
a `Set`, they would be roughly equivalent to `NSSet.member(_:)`.

The changes I consider most worthy include:

* Adding corresponding `last` and `suffix` methods for all 
  `first` and `prefix` methods.
  
* Adding corresponding `while:` versions of all appropriate 
  prefix/suffix APIs.

Ones that could be useful, but can usually be emulated with more work:

* Adding `remove`/`removing`-by-content APIs.

* Adding `prefix/suffixIndex(while:)`.

Ones that are mere conveniences or may not have strong use cases:

* `first/lastIndex` and `prefix/suffixIndex(_:)`.

* `first/last(_:)`.

#### "All" and "Every" as operands

One could imagine adding rows to this table for "all" and "every 
matching". In addition to creating some useful new API, this would 
also suggest some interesting renaming for existing APIs:

* `allIndices` would be a name for `indices`.

* `removeAll()` is actually an existing name which happens to fit this 
  pattern.

* `every(where:)` would be a name for `filter`. Though I believe `filter` 
  is a strong term of art, I do note that `every(where:)` does not 
  cause confusion about the sense of its test, a major complaint about 
  `filter`.

In the table below, **bold** indicates new functionality; *italics* 
indicates existing functionality renamed to fit this pattern.

|                                  | Get                | Index                    | Exclude                     | Remove (1)                | Pop (1)      | Equate (2)          |
| -------------------------------- | ------------------ | ------------------------ | --------------------------- | ------------------------- | ------------ | ------------------- |
| **Fixed Size**                   |
| First 1                          | C.first            | C.firstIndex             | S.removingFirst()           | C.removeFirst()           | C.popFirst() | -                   |
| Last 1                           | C.last             | C.lastIndex              | S.removingLast()            | C.removeLast()            | C.popLast()  | -                   |
| First (n: Int)                   | S.prefix(\_:)      | C.prefixIndex(\_:)       | S.removingPrefix(\_:)       | C.removePrefix(\_:)       | -            | S.hasPrefix(\_:)    |
| &nbsp;&nbsp;...with closure      | S.prefix(while:)   | C.prefixIndex(while:)    | S.removingPrefix(while:)    | C.removePrefix(while:)    | -            | S.hasPrefix(\_:by:) |
| Last (n: Int)                    | S.suffix(\_:)      | C.suffixIndex(\_:)       | S.removingSuffix(\_:)       | C.removeSuffix(\_:)       | -            | S.hasSuffix(\_:)    |
| &nbsp;&nbsp;...with closure      | S.suffix(while:)   | C.suffixIndex(while:)    | S.removingSuffix(while:)    | C.removeSuffix(while:)    | -            | S.hasSuffix(\_:by:) |
| All                              | -                  | *allIndices*             | -                           | C.removeAll()             | -            | -                   |
| **Searching From End**           |
| First&nbsp;matching&nbsp;element | S.first(\_:)       | C.firstIndex(of:)        | S.removingFirst(\_:)        | C.removeFirst(\_:)        | -            | -                   |
| &nbsp;&nbsp;...with closure      | S.first(where:)    | C.firstIndex(where:)     | S.removingFirst(where:)     | C.removeFirst(where:)     | -            | -                   |
| Last matching element            | S.last(\_:)        | C.lastIndex(of:)         | S.removingLast(\_:)         | C.removeLast(\_:)         | -            | -                   |
| &nbsp;&nbsp;...with closure      | S.last(where:)     | C.lastIndex(where:)      | S.removingLast(where:)      | C.removeLast(where:)      | -            | -                   |
| Every&nbsp;matching&nbsp;element | **S.every(\_:)**   | **C.everyIndex(of:)**    | **S.removingEvery(\_:)**    | **C.removeEvery(\_:)**    | -            | -                   |
| &nbsp;&nbsp;...with closure      | *S.every(where:)*  | **C.everyIndex(where:)** | **S.removingEvery(where:)** | **C.removeEvery(where:)** | -            | -                   |

An alternative to the `every` methods is to give them names based on 
`all` or `any`, but these tend to require breaks from the naming 
patterns of the matching `first` and `last` methods to remain 
grammatical.

#### Additional index-based operations

Though accessing a range of elements bounded by the end of the 
collection is useful, it might be useful to extend that ability to 
other range-based collection APIs. `IncompleteRange` would make this 
especially easy; we would simply overload `Range`-taking APIs to permit 
`IncompleteRange`s as well. However, we could also provide variants of 
these APIs which take a `to:`, `through:`, or `from:` index parameter 
in place of an index range.

Candidates include:

* `RangeReplaceableCollection.removeSubrange(\_:)`

* `RangeReplaceableCollection.replaceSubrange(\_:with:)`

* The various `Range` parameters in `String` (although these might be 
  better replaced with slice-based APIs).
