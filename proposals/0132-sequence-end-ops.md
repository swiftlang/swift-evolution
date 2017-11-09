# Rationalizing Sequence end-operation names

* Proposal: [SE-0132](0132-sequence-end-ops.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax), [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Awaiting Review** (Draft 2)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000267.html)

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

* Get value of element(s):
  * First: `first`
  * Last: `last`
  * Prefix of *n*: `prefix(3)`
  * Suffix of *n*: `suffix(3)`
  * Prefix all matching closure: `prefix(while: isOdd)`
  * Earliest matching closure: `first(where: isOdd)`
* Get index of element:
  * Earliest equal to value: `index(of: x)`
  * Earliest matching closure: `index(where: isPrime)`
* Return copy after removing element(s):
  * First: `dropFirst()`
  * Last: `dropLast()`
  * Prefix of *n*: `dropFirst(3)`
  * Suffix of *n*: `dropLast(3)`
  * Prefix all matching closure: `drop(while: isOdd)`
* Remove element(s):
  * First: `removeFirst()`
  * Last: `removeLast()`
  * Prefix of *n*: `removeFirst(3)`
  * Suffix of *n*: `removeLast(3)`
* Remove elements if present:
  * First: `popFirst()`
  * Last: `popLast()`
* Test equality:
  * Prefix of *n*: `starts(with: other)`, `starts(with: other, by: ==)`
    (where *n* is the parameter length)

Put next to each other, we see a lot of inconsistent terminology:

* Usually, "prefix of N" is handled by overloading a `first` method, except 
  on the most-used category, "get value of element(s)". There, we suddenly 
  use `prefix` and `suffix`.

* The "get index of element" methods do not indicate a direction, but adding 
  versions which search from the end would be very plausible. Similarly, 
  `drop(while:)` does not include a direction, but dropping a suffix of 
  matching elements is a plausible feature.

* "Return copy after removing element(s)" and "Remove element(s)" are  
  closely related, but they have unrelated names. The name `drop`, while a 
  term of art from functional languages, sounds like a mutating operation that 
  deletes data.

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

1. Each of these APIs should be renamed to use a word which consistently 
   indicates a direction and size:

| Operand                          | Word               |
| -------------------------------- | ------------------ |
| First                            | first              |
| Earliest equal to value          | first              |
| Earliest matching closure        | first              |
| Last                             | last               |
| Prefix of *n*                    | prefix             |
| Prefix all matching closure      | prefix             |
| Suffix of *n*                    | suffix             |

2. The `drop` methods should be renamed to `removing`, indicating their 
   relationship to `remove`.

3. The `starts(with:)` method should be renamed to `hasPrefix(_:)`, 
   bringing it into this scheme and aligning it with Foundation.

These changes yield (bold parts are different):

* Get value of element(s):
  * First: `first`
  * Last: `last`
  * Prefix of *n*: `prefix(3)`
  * Suffix of *n*: `suffix(3)`
  * Prefix all matching closure: `prefix(while: isOdd)`
  * Earliest matching closure: `first(where: isOdd)`
* Get index of element:
  * Earliest equal to value: `**first**Index(of: x)`
  * Earliest matching closure: `**first**Index(where: isPrime)`
* Return copy after removing element(s):
  * First: `**removing**First()`
  * Last: `**removing**Last()`
  * Prefix of *n*: `**removingPrefix**(3)`
  * Suffix of *n*: `**removingSuffix**(3)`
  * Prefix all matching closure: `**removingPrefix**(while: isOdd)`
* Remove element(s):
  * First: `removeFirst()`
  * Last: `removeLast()`
  * Prefix of *n*: `remove**Prefix**(3)`
  * Suffix of *n*: `remove**Suffix**(3)`
* Remove elements if present:
  * First: `popFirst()`
  * Last: `popLast()`
* Test equality:
  * Prefix of *n*: `**hasPrefix**(**other**)`, `**hasPrefix**(**other**, by: ==)`
    (where *n* is the parameter length)

The old names will be deprecated immediately. They'll be removed in Swift 5 so they do not needlessly inflate the stabilized standard library.

## Detailed design

The following methods should be renamed as follows wherever they appear 
in the standard library, and compatibility aliases should be added for the 
old names which call through to the new ones. These are simple textual 
substitutions; we propose no changes whatsoever to types, parameter 
interpretations, or other semantics.

[Note: still need to check and update this list.]

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

## Impact on existing code

Developers using these members will need to change to the new names when migrating to Swift 5. Compiler diagnostics and the migrator should be able to handle these changes with a low chance of mistakes.

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

