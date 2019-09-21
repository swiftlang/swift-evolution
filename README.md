# Collection Consumers and Searchers Prototype
Early prototype of generalized collection consumers and searchers, APIs powered by them, and a smattering of conformers.

Inspired by Rust’s [RFC-2500](https://github.com/rust-lang/rfcs/blob/master/text/2500-needle.md).


### Introduction

This prototype demonstrates two main protocols, `CollectionConsumer` and `CollectionSearcher`, and a suite of API generic over them.

Example:

```swift
"  \n\tThe quick brown fox\n".trim { $0.isWhitespace }
// "The quick brown fox"

[1,2,3,2,1,5,5,9,0,9,0,9,0,9].matches(PalindromeFinder()).map { $0.count }
// [5, 2, 7]

let number = try! NSRegularExpression(pattern: "[-+]?[0-9]*\\.?[0-9]+")
var str = "12.34,5,.6789\n10,-1.1"

str.split(number)
// [",", ",", "\n", ","]

str.matches(number).joined(separator: " ")
// "12.34 5 .6789 10 -1.1"

str.replaceAll(number) { "\(Double($0)!.rounded())" }
// str == "12.0,5.0,1.0\n10.0,-1.0"
```


#### How to Use

Add as package dependency:

URL: https://github.com/milseman/swift-evolution
branch: `collections_om_nom_nom`

Import with `import Prototype_CollectionConsumerSearcher`


#### Brief Background: The Royal Road to Regex

Native regex literals will be built on top of generic functionality and used with generic APIs. These can be broken down into 4 stages:

1. Consumers: nibbling off the front or back of a Collection
2. Searchers: finding a needle in a haystack (i.e. a Collection)
3. Validators: constructing types in the process of consuming/searching
4. [Destructuring Pattern Matching Syntax](https://gist.github.com/milseman/bb39ef7f170641ae52c13600a512782f#syntax-for-destructing-matching): Like `~=`, but can bind a value

Each stage delivers important API and syntax improvements to users alongside powerful extension points for libraries. Native regex literals would conform to these protocols and leverage new syntax, allowing them to be used by the same generic APIs.

This prototype covers stages 1 and 2.


### Caveats and Disclaimers (aka “This is Just a Prototype”)

#### Why So Much API?

I’m not sure yet what will be a super convenient overload vs excessive bloat, so I erred on the side of defining anything I thought might be useful. For the prototype’s purposes, this lets us see a broader array of functionality enabled from these constructs.


#### I Hate Your Names!

Since this is an early prototype and there’s a lot of API here, names were chosen to be clearly distinguished and follow a regular convention. I welcome any contributions towards solving one of the hardest problems in computer science: naming things.


#### But How Does it Perform?

No performance work has been done so far.

This prototype is written in a naive fashion without any tuning or optimization. Simple overloads are written in terms of the more general constructs, allowing for better testing and demonstration of how to use them, but this technique can result in overhead. In a perfect world, these could be optimized away (at the cost of some compilation time), but the reality of optimizers is that real world constraints lead to heuristic-driven decisions.

Once we have a design in place, we can write the benchmarks and do tuning. We’ll especially want to provide fast-paths for certain concrete types. E.g. if a String is normalized, operate directly over its UTF-8 bytes.

#### Can I Deploy This in Production?

Please don’t. Some parts have been heavily tested, but some have not. This is just meant to generate ideas and early feedback on the approach.



### Overview

#### Protocols

##### `CollectionConsumer`

Conformers to `CollectionConsumer` are able to perform a match anchored at some point:

```swift
public protocol CollectionConsumer {
  associatedtype C: Collection

  func consume(_: C, from: C.Index) -> C.Index?
}

public protocol BidirectionalCollectionConsumer: CollectionConsumer
where C: BidirectionalCollection {
  // Return value is 1-past-the-end
  func consumeBack(_: C, endingAt: C.Index) -> C.Index?
}
```

Consumer state can be created at the time of initialization (e.g. compiling a regex), persisted across many collections, and across repeated invocations for any given collection.

Generic API powered by `CollectionConsumer`:

```swift
extension Collection {
  public func trimFront<CC: CollectionConsumer>(_: CC) -> SubSequence
  where CC.C == Self

  public func starts<CC: CollectionConsumer>(with: CC) -> Bool where CC.C == Self
}

extension BidirectionalCollection {
  public func trimBack<CC: BidirectionalCollectionConsumer>(_: CC) -> SubSequence
  where CC.C == Self

  public func trim<CC: BidirectionalCollectionConsumer>(_: CC) -> SubSequence
  where CC.C == Self

  public func ends<CC: BidirectionalCollectionConsumer>(with: CC) -> Bool
  where CC.C == Self
}

extension RangeReplaceableCollection {
  public mutating func stripFront<CC: CollectionConsumer>(_: CC) where CC.C == Self
}

extension RangeReplaceableCollection where Self: BidirectionalCollection {
  public mutating func stripBack<CC: BidirectionalCollectionConsumer>(cc: CC)
  where CC.C == Self

  public mutating func strip<CC: BidirectionalCollectionConsumer>(cc: CC)
  where CC.C == Self
}

extension Collection where SubSequence == Self {
  @discardableResult
  public mutating func eat<CC: CollectionConsumer>(_: CC) -> SubSequence
  where CC.C == Self

  @discardableResult
  public mutating func eatAll<CC: CollectionConsumer>(_: CC) -> [SubSequence]
  where CC.C == Self
}
```


##### `CollectionSearcher`

Conformers to `CollectionSearcher` are able to perform a match anywhere from a staring point (not an anchor).

```swift
public protocol CollectionSearcher {
  associatedtype C: Collection

  associatedtype State = ()

  func preprocess(_: C) -> State

  func search(_: C, from: C.Index, _: inout State) -> Range<C.Index>?
}

public protocol BidirectionalCollectionSearcher: CollectionSearcher
where C: BidirectionalCollection {
  func searchBack(
    _ c: C, endingAt idx: C.Index, _: inout State
  ) -> Range<C.Index>?
}
```

Naively, any consumer can be made into a searcher with `O(n * m)` complexity. To achieve better performance, efficient searchers avoid redundant computation by managing state. Searcher conformers can choose to manage 3 levels of state:

 * Persisted state across all inputs, created during `init`
   * Examples: compile a regex, preprocess the search term
 * State persisted across calls for a given instance, created during `preprocess(_:C)`
   * Examples: check if a String is normalized, build up a suffix tree
 * State updated across calls for a given instance, via the `inout State` parameter to `search`
   * Examples: Z-algorithm’s Z array, fuzzy search context


Many searchers have no per-collection or cross-call state, so convenience implementations are provided for them:

```swift
extension CollectionSearcher where State == () {
  public func preprocess(_: C) -> State { return () }
}
```

Generic API powered by `CollectionSearcher`:

```swift

extension Collection {
  public func firstRange<CS: CollectionSearcher>(_: CS) -> Range<Index>?
  where CS.C == Self

  public func first<CS: CollectionSearcher>(_:) -> SubSequence?
  where CS.C == Self

  public func matches<CS: CollectionSearcher>(
    _: CS
  ) -> CollectionMatchSequence<Self, CS> // A Sequence of matched C.SubSequence

  public func split<CS: CollectionSearcher>(
    _: CS, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [SubSequence] where CS.C == Self
}

extension BidirectionalCollection {
  public func lastRange<CS: BidirectionalCollectionSearcher>(
    _: CS
  ) -> Range<Index>? where CS.C == Self

  public func last<CS: BidirectionalCollectionSearcher>(
    _: CS
  ) -> SubSequence? where CS.C == Self
}

extension RangeReplaceableCollection {
  public mutating func replaceFirst<C: Collection, CS: CollectionSearcher>(
    _: CS, with: (SubSequence) -> C
  ) where CS.C == Self, C.Element == Element

  public mutating func replaceAll<C: Collection, CS: CollectionSearcher>(
    _: CS, with: (SubSequence) -> C
  ) where CS.C == Self, C.Element == Element
}

extension RangeReplaceableCollection where Self: BidirectionalCollection {
  public mutating func replaceLast<
    C: Collection, CS: BidirectionalCollectionSearcher
  >(_: CS, with: (SubSequence) -> C) where CS.C == Self, C.Element == Element
}

extension Collection where SubSequence == Self {
  @discardableResult
  mutating func eat<CS: CollectionSearcher>(untilFirst: CS) -> SubSequence
  where CS.C == Self

  @discardableResult
  mutating func eat<CS: CollectionSearcher>(throughFirst: CS) -> SubSequence
  where CS.C == Self
}

extension BidirectionalCollection where SubSequence == Self {
  @discardableResult
  mutating func eat<CS: BidirectionalCollectionSearcher>(
    untilLast: CS
  ) -> SubSequence where CS.C == Self

  @discardableResult
  mutating func eat<CS: BidirectionalCollectionSearcher>(
    throughLast: CS
  ) -> SubSequence where CS.C == Self
}
```



#### Conformers

This prototype adds conformances for types from Foundation for user convenience:

```swift
extension CharacterSet: CollectionConsumer, CollectionSearcher {
  // For String, respecting grapheme-cluster boundaries
}
extension NSRegularExpression: CollectionConsumer, CollectionSearcher {
  // For String
}
extension Scanner: CollectionConsumer, CollectionSearcher {
  // For String, by forwarding on to `charactersToBeSkipped`
}
```

Since `CharacterSet` is effectively just a set of `Unicode.Scalar`, it doesn’t have to be limited to just `String`. This prototype adds the ability to construct a consumer/searcher for any collection of `Character`s, where it operates respecting grapheme-cluster boundaries, as well as for any collection of `Unicode.Scalar`, which ignores grapheme-cluster boundaries:

```swift
extension CharacterSet {
  public func searcher<C: Collection>(
    for: C.Type = C.self
  ) -> CharacterSearcher<C> where C.Element == Character

  public func searcher<C: Collection>(
    for: C.Type = C.self
  ) -> UnicodeScalarSearcher<C> where C.Element == Unicode.Scalar
}
```

(This approach will get a lot better when opaque result types can specify associated types)

This prototype also demonstrates how to conform 3rd party library types to these protocols, by providing conformances for:

* `PalindromeFinder`: A custom-written palindrome finder
* `StdlibPattern` from the [stdlib prototype](https://github.com/apple/swift/blob/master/test/Prototypes/PatternMatching.swift), which demonstrates a technique for retroactively providing this functionality to a stable protocol
* `Pattern` from [PatternKit](https://github.com/ctxppc/PatternKit), as an example conformance for an existing SPM package


* *TODO:* Provide a `NSPredicate` conformance, getting around the untyped-ness somehow
* *TODO:* Provide a generic [2-way search algorithm](https://www-igm.univ-mlv.fr/~lecroq/string/node26.html) when `Element: Comparable`, which will perhaps be the default search algorithm
* *TODO:* Provide a generic [Z Algorithm](https://github.com/raywenderlich/swift-algorithm-club/tree/master/Z-Algorithm) to demonstrate cross-call state.


#### Tour of API, Naming Convention, and Lexicon

* `CollectionConsumer`: A consumer returns a match anchored at a given position, else `nil`
  * Name taken directly from Rust, but not ideal (has nothing in common with `__consuming`, could imply mutation, etc.)
  * “Trimmer” could be another name, but that overweights one specific use for it
* `CollectionSearcher`: A searcher returns the next match anywhere after a given position, else `nil`
* `BidirectionalCollectionConsumer` / `BidirectionalCollectionSearcher`
  * Can run matching logic backwards over a `BidirectionalCollection`
* Generalized `trim`, non-mutating operations returning the rest of the collection after a consumption from the head/tail/both.
  * `trimFront` is available on all collections and consumes a prefix. `trimBack` and `trim` are available on bidirectional collections/consumers
    * `trimBack` consumes a suffix and `trim` consumes both a prefix and a suffix.
    * All of the APIs below exist for all 3 forms, but I will just be listing `trim`
  * `trim(_: BidirectionalCollectionConsumer)`: Generalized trim operation
  * `trim(_: Element)`, `trim(_: (Element) -> Bool)` trims off all leading and trailing occurrences
  * `trim(in: Set<Element>)` trims off the leading and trailing elements which are present in the set
    * `trim(anyOf: Sequence)`: does the same thing; it is a convenience overload present in many languages/libraries
    * Argument label helps disambiguate Set and Array literals, which use the same syntax
  * `trim(exactly: Sequence)`: trims a single occurrence of a prefix and suffix
    * Argument label helps disambiguate Character and String literals, which use the same syntax
  * `strip` is the mutating version of trim
    * There is a corresponding `strip` API for every `trim` API for `RangeReplaceableCollecitons`
* Generalization of existing APIs through consumers
  * `starts(with:)` / `ends(with:)` taking `CollectionConsumer` / `BidirectionalCollectionConsumer`
  * *TODO*: consider adding `drop` / `dropBack`, `prefix` / `suffix`, `removeFirst` / `removeLast`
* Generalized `eat` available on slices: advances the slice’s range as part of a successful match
  * Om nom nom 🍪
  * All eat methods return what was eaten as a `@discardableResult`, else `nil` if nothing happened.
  * `eat(_:CollectionConsumer)`: generalized eat operation
  * `eat(upTo:Index)` adjusts the slice’s `lowerBound`, `eat(from:Index)` adjusts the slice’s `upperBound`
  * `eat(untilFirst: CollectionSearcher)`, `eat(throughFirst: CollectionSearcher)` generalized eat until/through the first match in the slice
    * Convenience overloads for `(Element) -> Bool)`, `Set<Element>`, `Element`
  * `eat(untilLast: BidirectionalCollectionSearcher)`, `eat(throughLast: BidirectionalCollectionSearcher)` generalized eat until/through the last match in the slice
    * Convenience overloads for `(Element) -> Bool)`, `Set<Element>`, `Element`,
  * `eat()` , `eat(one: (Element) -> Bool)`, `eat(one: Element)`, `eat(oneIn: Set<Element>)` eats a single `Element` off
  * `eat(count: Int)`, `eat(while: (Element) -> Bool)`, `eat(many: Element)`, and `eat(whileIn: Set<Element>)` eat many off
  * `eat(exactly: Sequence)` eats one occurrence of a given prefix
* Generalized find and replace operations
  * `firstRange(_:CollectionSearcher)` / `first(_:CollectionSearcher)` return the range/slice of the first match
    * Convenience overload taking `Sequence`
    * Corresponding `lastRange` and `last` for `BidirectionalCollectionSearcher`
  * `replaceFirst(_: CollectionSearcher, with: (SubSequence) -> Collection` passes first match to a closure to generate the replacement
    * `replaceAll` does them all
    * Corresponding `replaceLast`  for `BidirectionalCollectionSearcher`
* Generalized access to matches from a searcher
  * `Collection.matches(_: CollectionSearcher)` produces a lazy sequence of successful search matches
    * *TODO:* Make an unknown-count collection, like other lazy operations
    * *TODO:* Make it bidirectional if the collection/searcher is
  * `Collection.split(_:CollectionSearcher, …) -> [SubSequence]`: generalized split



#### *TODO:* Slicing Problem

Some conformers would like to be applied to both `C` and `C.SubSequence`. One approach is to change the protocol requirement to take a slice, and add overloads over `C.SubSequence` for every API.

Workaround: for conformers generic over the collection, there is no issue. For concrete type conformers, they can often vend generic helper structs. See `CharacterSet.searcher(for:)` pattern above.



### What’s Next?

I want to let this circulate for a while to collect ideas, opinions, and use cases.

Before any formal pitch or proposal, I want to have a good idea of what type validators will look like in order to avoid making incongruous API decisions early on.

