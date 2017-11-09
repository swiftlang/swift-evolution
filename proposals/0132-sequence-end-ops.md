# Rationalizing Sequence end-operation names

* Proposal: [SE-0132](0132-sequence-end-ops.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax), [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Awaiting Review** (Draft 2)
* Implementation: **Needs Updating** [apple/swift#3793](https://github.com/apple/swift/pull/3793) 
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

The following methods will be renamed as follows wherever they appear 
in the standard library. During the Swift 4 cycle, compatibility aliases 
will be available for the old names which call through to the new ones.

These are simple textual substitutions; we propose no changes whatsoever 
to types, parameter interpretations, or other semantics.

[**FIXME**: Need to check and update this list.]

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

An implementation is available in [pull request 3793](https://github.com/apple/swift/pull/3793)
[**FIXME**: but it is currently out of date.]

## Source compatibility

Developers using these members will need to change to the new names when migrating 
to Swift 5. Compiler diagnostics and the migrator should be able to handle 
these changes with a low chance of mistakes.

In practice, we believe the changes to the underused `drop` methods will be 
the least impactful. `removeFirst(_:)` and `removeLast(_:)` are probably also 
used infrequently. `starts(with:)` will have some impact, mitigated by the 
presence of `hasPrefix(_:)` on `String`.

Changing `index(of:)` and `index(where:)` will have relatively widespread impact, 
but the migrator should handle them gracefully, and a pair of `lastIndex` methods 
seem like a relatively likely addition to Swift in the future.

Developers using Swift 4.1 or later will see deprecation warnings, but don't need 
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
etc. This would change fewer names, but the names it would change are 
probably more frequently used, and it would further overload the `first` 
and `last` properties with methods, which is confusing and potentially 
ambiguous. We also think it wouldn't read as clearly. Finally, it would 
foreclose the use of, for instance, `removeFirst(x)` to remove the first 
element equal to `x`.

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
