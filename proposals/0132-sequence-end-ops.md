# Rationalizing Sequence end-operation names

* Proposal: [SE-0132](0132-sequence-end-ops.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax), [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Awaiting Review** (Draft 2)
* Implementation: [apple/swift#3793](https://github.com/apple/swift/pull/3793) 
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/3abbed3edd12dd21061181993df7952665d660dd/proposals/0132-sequence-end-ops.md)

## Introduction

Sequence and Collection offer many special operations which access or 
manipulate its first or last elements, but they are plagued by 
inconsistent naming which can make it difficult to find inverses or 
remember what the standard library offers. We propose that we standardize 
these names so they follow consistent, predictable patterns.

Swift-evolution thread: [[Draft] Rationalizing Sequence end-operation names](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/021872.html)

## Motivation

The `Sequence` and `Collection` protocols offer a wide variety of APIs 
which are defined to operate on, or from, one end of the sequence. Leaving 
aside the `prefix(from:)`, `prefix(upTo:)`, and `prefix(through:)` methods, 
which were obsoleted by [SE-0172][onesided], we have:

  [onesided]: (0172-one-sided-ranges.md)
  
| Operation        | Operand                           | Current name                  |
| ---------------- | --------------------------------- | ----------------------------- |
| Get value        | First element                     | `first`                       |
| "                | Last element                      | `last`                        |
| "                | First *n* elements                | `prefix(3)`                   |
| "                | Last *n* elements                 | `suffix(3)`                   |
| "                | Leading elements matching closure | `prefix(while: isOdd)`        |
| "                | Earliest element matching closure | `first(where: isOdd)`         |
| Get index        | Earliest element equal to value   | `index(of: x)`                |
| "                | Earliest element matching closure | `index(where: isOdd)`         |
| Remove from copy | First element                     | `dropFirst()`                 |
| "                | Last element                      | `dropLast()`                  |
| "                | First *n* elements                | `dropFirst(3)`                |
| "                | Last *n* elements                 | `dropLast(3)`                 |
| "                | Leading elements matching closure | `drop(while:)`                |
| Remove from self | First element                     | `removeFirst()`               |
| "                | Last element                      | `removeLast()`                |
| "                | First *n* elements                | `removeFirst(3)`              |
| "                | Last *n* elements                 | `removeLast(3)`               |
| …if present      | First element                     | `popFirst()`                  |
| "                | Last element                      | `popLast()`                   |
| Test equality    | First *n* elements                | `starts(with: other)`         |
| …with function   | "                                 | `starts(with: other, by: ==)` |

Put next to each other, we see a lot of inconsistent terminology:

* Usually, "first *n* elements" is handled by overloading a `first` method, except 
  on the most-used category, "get value of element(s)". There, we suddenly 
  use `prefix` and `suffix`.

* The "get index" methods do not indicate a direction, but adding 
  versions which search from the end would be very plausible. Similarly, 
  `drop(while:)` does not include a direction, but dropping trailing elements is a plausible feature.

* "Remove from copy" and "Remove from self" are 
  closely related, but they have unrelated names. The name `drop`, while a 
  term of art from functional languages, sounds like a mutating operation that 
  deletes data; in particular, developers experienced with SQL may find "drop" 
  alarming.

* `starts(with:)` looks like nothing else in this list, even though it does 
  similar things, and even though Foundation uses `hasPrefix(_:)`, which 
  *does* sound like other entries in this table.

This inconsistency makes the standard library's collection APIs seem 
disorganized and incomplete. It obscures the fact that we already support 
a lot of functionality that people want to have. It makes it awkward to 
add new functionality; for instance, we might like to add a call that 
removes the first element equal to a given element, but `removeFirst(_:)` 
already does something unrelated.

## Proposed solution

We should rename these methods to always use `first` or `last` to indicate 
they operate on a single element, or `prefix` or `suffix` to indicate they 
operate on many elements. Future APIs should follow this rule as well; for 
instance, a method which removed and returned *n* leading elements should 
be called `popPrefix(_:)`, not `popFirst(_:)` or `pop(_:)`.

Additionally, the `drop` methods should be renamed with `removing`, to 
match their mutating counterparts, which use `remove`.

The old names should be deprecated immediately and removed in Swift 5 to avoid making them 
part of the permanent ABI.

These changes yield (bold parts are different):

| Operation        | Operand                           | Current name                  | New name                                 |
| ---------------- | --------------------------------- | ----------------------------- | ---------------------------------------- |
| Get value        | First element                     | `first`                       | `first`                                  |
| "                | Last element                      | `last`                        | `last`                                   |
| "                | First *n* elements                | `prefix(3)`                   | `prefix(3)`                              |
| "                | Last *n* elements                 | `suffix(3)`                   | `suffix(3)`                              |
| "                | Leading elements matching closure | `prefix(while: isOdd)`        | `prefix(while: isOdd)`                   |
| "                | Earliest element matching closure | `first(where: isOdd)`         | `first(where: isOdd)`                    |
| Get index        | Earliest element equal to value   | `index(of: x)`                | **`first`**`Index(of: x)`                |
| "                | Earliest element matching closure | `index(where: isOdd)`         | **`first`**`Index(where: isOdd)`         |
| Remove from copy | First element                     | `dropFirst()`                 | **`removing`**`First()`                  |
| "                | Last element                      | `dropLast()`                  | **`removing`**`Last()`                   |
| "                | First *n* elements                | `dropFirst(3)`                | **`removingPrefix`**`(3)`                |
| "                | Last *n* elements                 | `dropLast(3)`                 | **`removingSuffix`**`(3)`                |
| "                | Leading elements matching closure | `drop(while:)`                | **`removingPrefix`**`(while: isOdd)`     |
| Remove from self | First element                     | `removeFirst()`               | `removeFirst()`                          |
| "                | Last element                      | `removeLast()`                | `removeLast()`                           |
| "                | First *n* elements                | `removeFirst(3)`              | `remove`**`Prefix`**`(3)`                |
| "                | Last *n* elements                 | `removeLast(3)`               | `remove`**`Suffix`**`(3)`                |
| …if present      | First element                     | `popFirst()`                  | `popFirst()`                             |
| "                | Last element                      | `popLast()`                   | `popLast()`                              |
| Test equality    | First *n* elements                | `starts(with: other)`         | **`hasPrefix`**`(`**`other`**`)`         |
| …with function   | "                                 | `starts(with: other, by: ==)` | **`hasPrefix`**`(`**`other`**`, by: ==)` |

## Detailed design

An implementation is available in [pull request 3793](https://github.com/apple/swift/pull/3793),

No types, parameter positions, or semantics should change because of this 
proposal—it merely affects names. The vast majority of the impact of this 
feature is not in the Swift libraries themselves, but in benchmarks, tests, 
and documentation comments.

The following protocol requirements will be renamed:

| Protocol                     | Old name                | New name                  |
| ---------------------------- | ----------------------- | ------------------------- |
| `Sequence`                   | `dropFirst(_:)`         | `removingPrefix(_:)`      |
| `Sequence`                   | `drop(while:)`          | `removingPrefix(while:)`  |
| `Sequence`                   | `dropLast(_:)`          | `removingSuffix(_:)`      |
| `RangeReplaceableCollection` | `removeFirst(_:)`       | `removePrefix(_:)`        |
| `RangeReplaceableCollection` | `_customRemoveLast(_:)` | `_customRemoveSuffix(_:)` |

Deprecated compatibility wrappers will be installed in extensions on the 
following protocols in Swift 4.1, and removed in Swift 5:

| Protocol                                                         | Deprecated name    |
| ---------------------------------------------------------------- | ------------------ |
| `Sequence`                                                       | `drop(while:)`     |
| `Sequence`                                                       | `dropFirst()`      |
| `Sequence`                                                       | `dropFirst(_:)`    |
| `Sequence`                                                       | `dropLast()`       |
| `Sequence`                                                       | `dropLast(_:)`     |
| `Sequence`                                                       | `starts(with:by:)` |
| `Sequence where Element: Equatable`                              | `starts(with:)`    |
| `Collection`                                                     | `index(where:)`    |
| `Collection where Element: Equatable`                            | `index(of:)`       |
| `Collection where SubSequence == Self`                           | `removeFirst(_:)`  |
| `RangeReplaceableCollection`                                     | `removeFirst(_:)`  |
| `BidirectionalCollection where SubSequence == Self`              | `removeLast(_:)`   |
| `RangeReplaceableCollection where Self: BidirectionalCollection` | `removeLast(_:)`   |

(A couple more may be needed on `RangeReplaceableCollection` to resolve ambiguities with 
`removeFirst(_:)` and `removeLast(_:)`.)

Concrete implementations of the following methods, throughout the standard library, will 
be renamed:

| Current name                      | New name                                   |
| --------------------------------- | ------------------------------------------ |
| `index(of: Element)`              | `firstIndex(of: Element)`                  |
| `index(where: (Element) -> Bool)` | `firstIndex(where: (Element) -> Bool)`     |
| `dropFirst()`                     | `removingFirst()`                          |
| `dropLast()`                      | `removingLast()`                           |
| `dropFirst(_: Int)`               | `removingPrefix(_: Int)`                   |
| `dropLast(_: Int)`                | `removingSuffix(_: Int)`                   |
| `drop(while: (Element) -> Bool)`  | `removingPrefix(while: (Element) -> Bool)` |
| `removeFirst(_: Int)`             | `removePrefix(_: Int)`                     |
| `removeLast(_: Int)`              | `removeSuffix(_: Int)`                     |
| `starts(with: PossiblePrefix)`    | `hasPrefix(_: PossiblePrefix)`             |
| `starts(with: PossiblePrefix, by: (Element, Element) -> Bool)` | `hasPrefix(PossiblePrefix, by: (Element, Element) -> Bool)` |

Some internal types, methods, and properties will be renamed as well.

The following things are currently *not* being renamed, but perhaps should be:

* `Collection._customIndexOfEquatableElement(_:)` requirement
* `LazyDropWhileCollection` struct

## Source compatibility

Developers using these members will need to change to the new names when migrating 
to Swift 5. Compiler diagnostics and the migrator should be able to handle 
these changes with a low chance of mistakes.

In the Swift Source Compatibility Suite, a simple regular-expression-based 
analysis suggests that less than 1 in 1,300 lines of code would be affected 
by this proposal: 

| Method              | Uses     |
| ------------------- | -------- |
| `index(where:)`     | 153      |
| `index(of:)`        | 76       |
| `dropFirst()`       | 36       |
| `dropLast()`        | 21       |
| `starts(with:)`     | 14       |
| `dropFirst(_:)`     | 9        |
| `dropLast(_:)`      | 5        |
| `removeFirst(_:)`   | 5        |
| `removeLast(_:)`    | 5        |
| `drop(while:)`      | 1        |
| `starts(with:by:)`  | 0        |
| Any match           | 325      |
| Total lines of code | 431,816* |

(* "Total lines of code" excludes comments and blank lines, but the use counts 
include all lines which appear to contain a use of the method, including 
comments.)

70% of matching lines use `index(of:)` or `index(where:)`; this agrees with 
our intuition that these methods are the most frequently used ones we propose 
to rename. We think this is worth the cost anyway. Migration should be 
accurate and uncomplicated, and a pair of `lastIndex` methods seems like a 
likely future addition to Swift.

Developers using Swift 4.1 or later will see deprecation warnings at the 
same rate Swift 5 users will need to change methods, but they won't need 
to fix them immediately.

## Effect on ABI stability

Without this proposal, the old, suboptimal names would be frozen in the ABI.

We propose removing the old names in Swift 5 so they do not become part of the 
permanent standard library ABI. If the impact on source stability is considered 
more important than a dozen redundant symbols, we could instead leave them 
deprecated but available permanently.

## Effect on API resilience

None.

## Alternatives considered

### `skipping` instead of `removing`

If the type differences are seen as disqualifying `removing` as a 
replacement for `drop`, we suggest using `skipping` instead.

There are, of course, *many* possible alternatives to `skipping`; this 
is almost a perfect subject for bikeshedding. We've chosen `skipping` 
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
either these axes or other ones. (We would be particularly interested in 
names other than `removing` which draw an analogy to something else in 
Swift.)

### Use just `first` and `last`

Instead of using `prefix` and `suffix` for multiple elements, we could use 
`first` and `last` for everything—`first(3)` for the first three elements, 
etc. We rejected this option because:

1. It would probably impact source stability more. The compatibility suite 
   appears to have 441 hits for the affected methods instead of 325.

2. It would further overload the `first` and `last` properties with methods; 
   we believe this would be confusing.

3. It would produce names that we think don't read as clearly, like `x.hasFirst(y)`.

4. It would foreclose other uses of these names, such as a 
   `RangeReplaceableCollection.removeFirst(_: Element)` method, which we 
   think might be good additions to the standard library.

## Out of scope

### Adding functionality to the standard library

This renaming exposes some gaps in our standard library functionality. For 
instance, `removingPrefix(while:)`, `hasPrefix(_:)`, `firstIndex(of:)`, etc. 
have no end-of-collection equivalents. It's tempting to fill these gaps, but 
these changes are purely additive and have no impact on ABI compatibility, 
so there's no need to consider them in this proposal.

### Renaming higher-order methods

`Sequence` methods like `map`, `filter`, `flatMap`, and `reduce` also do not 
follow typical API Guideline conventions, but they don't fit into the name 
scheme proposed here, and renaming them would be much more controversial. If 
someone wants to make the case to rename them, they should do it in a 
separate proposal.
