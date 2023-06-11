# Sequence `grouped(by:)` and `keyed(by:)`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Alexander Momchilov](https://github.com/amomchilov)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

This proposal would add new APIs on `Sequence` which let you group up or key elements in a more natural and fluent way than is currently possible with `Dictionary`'s initializers.

## Motivation

[SE-0165 Dictionary & Set Enhancements](https://github.com/apple/swift-evolution/blob/main/proposals/0165-dict.md) introduced some great utility APIs to Dictionary. Relating to this proposal are these 3 initializers:

1. [`Dictionary.init(grouping:by:)`](https://developer.apple.com/documentation/swift/dictionary/init(grouping:by:))
2. [`Dictionary.init(uniqueKeysWithValues:)`](https://developer.apple.com/documentation/swift/dictionary/init(uniquekeyswithvalues:))
3. [`Dictionary.init(_:uniquingKeysWith:)`](https://developer.apple.com/documentation/swift/dictionary/init(_:uniquingkeyswith:))

These APIs have proven very useful, and have replaced a plethora of hand-rolled calls to `reduce(into: [:]) { ... }`, but as initializers, they have some usability short comings.

### Grouping

It's not uncommon that you would like to group the results of a chain of method calls that transform a Sequence, and perhaps even keep chaining more transformations onto that Dictionary. For example:

```swift
let studentsWithDuplicateNames = Dictionary(
		grouping: loadPeople()
			.map { json in decoder.decode(Person.self, from: json) }
			.filter(\.isStudent),
		by: \.firstName
	).filter { name, students in students.count > 1 }
```

The initializer breaks down the simple top-to-bottom flow, and makes readers need to scan from the middle, to the top, and back to the bottom to follow the flow of transformations of values.

If this same capability existed as a method on `Sequence`, then the code can be much more fluent and prose-like:

```swift
let studentsWithDuplicateNames = loadPeople()
	.map { json in decoder.decode(Person.self, from: json) }
	.filter(\.isStudent),
	.grouped(by: \.firstName) // Replaces Dictionary.init(grouping:by:)
	.filter { name, students in students.count > 1 }
```

## Keying by a value

Many usages of [`Dictionary.init(uniqueKeysWithValues:)`](https://developer.apple.com/documentation/swift/dictionary/init(uniquekeyswithvalues:)) and [`Dictionary.init(_:uniquingKeysWith:)`](https://developer.apple.com/documentation/swift/dictionary/init(_:uniquingkeyswith:)) are expressing the idea of creating a Dictionary of values keyed by the some key (typically derived from the values themselves).  [Many such uses](https://github.com/search?q=%2Fdictionary%5C%28uniqueKeysWithValues%3A.*%5C.map%2F+language%3ASwift&type=code&l=Swift) can be found where these initializers are paired with a call to `map`. This introduces syntactic complexity and an intermediate Array allocation, if the author doesn't remember to call `.lazy.map`.

```swift
let studentsById = Dictionary(
	uniqueKeysWithValues: loadPeople()
		.map { json in decoder.decode(Person.self, from: json) }
		.filter(\.isStudent)
		.map { student in (key: student.id, value: student) }
)
```

This initializer is pretty syntactically heavy, its combination with `map` is a non-obvious pattern, and it suffers from the same reading up-and-down problem as the grouping case.

This concept could be expressed more clearly, and the intermediate array allocation can be spared, if this was a method on `Sequence`:

```swift
let studentsById = loadPeople()
	.map { json in decoder.decode(Person.self, from: json) }
	.filter(\.isStudent)
	.keyed(by: \.id)
```

### Prior art

| Language      | Grouping API | "Keying" API |
|---------------|--------------|-------------|
| Java          | [`groupingBy`](https://docs.oracle.com/en/java/javase/20/docs/api/java.base/java/util/stream/Collectors.html#groupingBy(java.util.function.Function)) | [`toMap`](https://docs.oracle.com/en/java/javase/20/docs/api/java.base/java/util/stream/Collectors.html#toMap(java.util.function.Function,java.util.function.Function)) |
| Kotlin        | [`groupBy`](https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.collections/group-by.html) | [`associatedBy`](https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.collections/associate-by.html) |
| C#            | [`GroupBy`](https://learn.microsoft.com/en-us/dotnet/api/system.linq.enumerable.groupby?view=net-7.0#system-linq-enumerable-groupby) | [`ToDictionary`](https://learn.microsoft.com/en-us/dotnet/api/system.linq.enumerable.todictionary?view=net-7.0#system-linq-enumerable-todictionary) |
| Rust          | [`group_by`](https://doc.rust-lang.org/std/primitive.slice.html#method.group_by) | - |
| Ruby          | [`group_by`](https://ruby-doc.org/3.2.2/Enumerable.html#method-i-group_by) | [`index_by`](https://rubydoc.info/gems/activesupport/7.0.5/Enumerable#index_by-instance_method) |
| Python        | [`groupby`](https://docs.python.org/3/library/itertools.html#itertools.groupby) | [dict comprehensions](https://peps.python.org/pep-0274/) |
| PHP (Laravel) | [`groupBy`](https://laravel.com/docs/10.x/collections#method-groupby) | [`keyBy`](https://laravel.com/docs/10.x/collections#method-keyby) |

## Proposed solution

This proposal introduces 2 new methods on `Sequence`. Here are simple examples of their usages:

```swift
let digitsGroupedByMod3 = (0...9).grouped(by: { $0 % 3 })
// Results in:
[
	0: [0, 3, 6, 9],
	1: [1, 4, 7],
	2: [2, 5, 8],
]

let fruitsByFirstLetter = ["Apple", "Banana", "Cherry"].keyed(by: { $0.first! })
// Results in:
[
	"A": "Apple",
	"B": "Banana",
	"C": "Cherry",
]
```

## Detailed design

```swift
extension Sequence {
	/// Groups up elements of `self` into a new Dictionary,
	/// whose values are Arrays of grouped elements,
	/// each keyed by the group key returned by the given closure.
	/// - Parameters:
	///   - keyForValue: A closure that returns a key for each element in
	///     `self`.
	/// - Returns: A dictionary containing grouped elements of self, keyed by
	///     the keys derived by the `keyForValue` closure.
	func grouped<GroupKey>(
		by keyForValue: (Element) throws -> GroupKey
	) rethrows -> [GroupKey: [Element]]

	/// Creates a new Dictionary from the elements of `self`, keyed by the
	/// results returned by the given `keyForValue` closure. As the dictionary is
	/// built, the initializer calls the `combine` closure with the current and
	/// new values for any duplicate keys. Pass a closure as `combine` that
	/// returns the value to use in the resulting dictionary: The closure can
	/// choose between the two values, combine them to produce a new value, or
	/// even throw an error.
	///
	/// If no `combine` closure is provided, deriving the same duplicate key for
	/// more than one element of self results in a runtime error.
	///
	/// - Parameters:
	///   - keyForValue: A closure that returns a key for each element in
	///     `self`.
	///     dictionary.
	///   - combine: A closure that is called with the values for any duplicate
	///     keys that are encountered. The closure returns the desired value for
	///     the final dictionary.
	func keyed<Key>(
		by keyForValue: (Element) throws -> Key,
		uniquingKeysWith combine: ((Key, Element, Element) throws -> Element)? = nil
	) rethrows -> [Key: Element]
}
```

## Source compatibility

All the proposed additions are purely additive.

## ABI compatibility

This proposal is purely an extension of the standard library which
can be implemented without any ABI support.

## Implications on adoption

TODO

The compatibility sections above are focused on the direct impact
of the proposal on existing code.  In this section, describe issues
that intentional adopters of the proposal should be aware of.

For proposals that add features to the language or standard library,
consider whether the features require ABI support.  Will adopters need
a new version of the library or language runtime?  Be conservative: if
you're hoping to support back-deployment, but you can't guarantee it
at the time of review, just say that the feature requires a new
version.

Consider also the impact on library adopters of those features.  Can
adopting this feature in a library break source or ABI compatibility
for users of the library?  If a library adopts the feature, can it
be *un*-adopted later without breaking source or ABI compatibility?
Will package authors be able to selectively adopt this feature depending
on the tools version available, or will it require bumping the minimum
tools version required by the package?

If there are no concerns to raise in this section, leave it in with
text like "This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility."

## Alternatives considered

### Wait for a "pipe" operator, and just use the existing initializers

The general issue here is the ergonomics of free functions (and similarly, initializers and static functions), and how they don't chain together as nicely as instance functions. There has been community discussion around introducing a generalized solution to this problem, usually an Elixir-style [pipe operator](https://elixir-lang.org/getting-started/enumerables-and-streams.html#the-pipe-operator), `|>`.

This operator takes the value on its left, and passes it as the first argument to the function passed to its right. It might look like so:

```swift
let studentsWithDuplicateNames = loadPeople()
	.map { json in decoder.decode(Person.self, from: json) }
	.filter(\.isStudent),
	|> { Dictionary(grouping: $0 by: \.name) }
	.filter { name, students in students.count > 1 }
```

This composes nicely, and reuses the existing Dictionary initializer, but brings its own challenges.

`Dictionary(grouping:by:)` takes two arguments, but the `|>` operator would expect a right-hand-side closure that takes only 1 argument. Resolving this requires one of several approaches, each with some downsides:
	1. Explicitly wrap the rhs in a closure as shown. This is quite noisy.
	2. Introduce a generalized function-currying syntax that can take `Dictionary.init(grouping:by:)`, bind the `by` argument to `\.name`, and return a single-argument function. This seems unlikely to be added to the language, and a long way off in any case.
	3. Implement the `|>` as a special form in the language, that gives it special behaviour for cases like this. (e.g. `|> Dictionary(grouping:by: \.name)`). This adds syntactic complexity to the language, and privileges the first argument over the others, which might not always work nicely.

In any case, the resultant spelling would still be quite wordy, and less clear than the simple `grouped(by:)` and `keyed(by:)` methods.

### Don't pass the `Key` to `keyed(by:)`'s `combine` closure

The proposed `keyed(by:combine:)` API takes an optional `combine` closure with this type:

```swift
(Key, Element, Element) throws -> Element
```

This differs from the `combine` closure expected by the current `Dictionary.init(_:uniquingKeysWith:)` API, which only passes the old and new element, but not the `Key`:

```swift
(Element, Element) throw -> Element
```

If the caller needs the `key` in their decision to pick between the old and new value, they would be required to re-compute it for themselves. This looks like a needless artificial restriction: at the point at which the `combine` closure is called, the key is already available, and it could just be provided directly.

### `groupedBy` and `keyedBy`

The `by:` argument labels are lost when using trailing-closure syntax:

```swift
(0...9).grouped { $0 % 3 }
```

Authors are forced to pick between the terseness of closure syntax as shown, or the prose-like clarity of regular closure passing:

```swift
(0...9).grouped(by: { $0 % 3 })
```

There's a fair argument to be made that the best of both worlds would be to move the `by:` from the argument label, into the function's base name, allowing for these two spellings:

```swift
(0...9).groupedBy({ $0 % 3 })
(0...9).groupedBy { $0 % 3 }
```


## Acknowledgments

None (yet?)
