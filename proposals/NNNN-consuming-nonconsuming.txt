# Formally defining `consuming` and `nonconsuming` argument type modifiers

* Proposal: [SE-NNNN](NNNN-consuming-nonconsuming.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Andrew Trick](https://github.com/atrick)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Pitch v1: [https://github.com/gottesmm/swift-evolution/blob/consuming-nonconsuming-pitch-v1/proposals/000b-consuming-nonconsuming.md](https://github.com/gottesmm/swift-evolution/blob/consuming-nonconsuming-pitch-v1/proposals/000b-consuming-nonconsuming.md)

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

By default the Swift compiler uses simple heuristics to determine whether a
function takes ownership of its arguments. In some cases, these heuristics
result in compiled code that forces the caller or callee to insert unnecessary
copies and destroys. We propose new `consuming` and `nonconsuming` argument type
modifiers to allow developers to override said compiler heuristics and
explicitly chose the convention used by the compiler when writing performance
sensitive code.

Pitch thread: [https://forums.swift.org/t/pitch-formally-defining-consuming-and-nonconsuming-argument-type-modifiers](https://forums.swift.org/t/pitch-formally-defining-consuming-and-nonconsuming-argument-type-modifiers)

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

In Swift, all non-trivial function arguments use one of two conventions that
specify if a caller or callee function is responsible for managing the
argument's lifetime. The two conventions are:

* **`consuming`**. The caller function is transferring ownership of a value to
  the callee function. The callee then becomes responsible for managing the
  lifetime of the value. Semantically, this is implemented by requiring the
  caller to emit an unbalanced retain upon the value that then must be balanced
  by a consuming operation in the callee. This unbalanced retain causes such an
  operation to be called "passing the argument at +1".

* **`nonconsuming`**. The caller function is lending ownership of a value to the
  callee. The callee does not own the value and must retain the value to consume
  it (e.x.: passing as a consuming argument). A reference counted `nonconsuming`
  argument is called a "+0 argument" since it is passed without emitting an
  unbalanced retain (in contrast to a "+1 argument") and all retain/release pairs
  are properly balanced locally within the caller/callee rather than over the
  call boundary.

By default Swift chooses which convention to use based upon the function type of
the callee as well as the position of the argument in the callee's argument
list. Specifically:

1. If a callee is an initializer, then an argument is always passed as
   `consuming`.

2. If a callee is a setter, then an argument is passed as `consuming` if the
   argument is a non-self argument.

3. Otherwise regardless of the callee type, an argument is always passed as
   `nonconsuming`.

Over all, these defaults been found to work well, but in performance sensitive
situations an API designer may need to customize these defaults to eliminate
unnecessary copies and destroys. Despite that need, today there does not exist
source stable Swift syntax for customizing those defaults.

## Motivating Examples

Despite the lack of such source stable syntax, to support the stdlib, the
compiler has for some time provided underscored, source unstable keywords that
allowed stdlib authors to override the default conventions:

1. `__shared`. This is equivalent to `nonconsuming`.
2. `__owned`. This is equivalent to `consuming`.
3. `__consuming`. This is used to have methods take self as a `consuming` argument.

Here are some examples of situations where developers have found it necessary to
use these underscored attributes to eliminate overhead caused by using the
default conventions:

* Passing a non-consuming argument to an initializer or setter if one is going
  to consume a value derived from the argument instead of the argument itself.

  1. [String initializer for Substring](https://github.com/apple/swift/blob/09507f59cf36e83ebc2d1d1ab85cba8f4fc2e87c/stdlib/public/core/Substring.swift#L22). This API uses the underscored API `__shared` since semantically the author's want to create a String that is a copy of the substring. Since the Substring itself is not being consumed, without __shared we would have additional ref count traffic.
   ```swift
   extension String {
     /// Creates a new string from the given substring.
     ///
     /// - Parameter substring: A substring to convert to a standalone `String`
     ///   instance.
     ///
     /// - Complexity: O(*n*), where *n* is the length of `substring`.
     @inlinable
     public init(_ substring: __shared Substring) {
       self = String._fromSubstring(substring)
     }
   }
   ```
  2. Initializing a cryptographic algorithm state by accumulating over a collection. Example: [ChaCha](  https://github.com/apple/swift/blob/324cccd18e9297b3cea9fc88d1ce80a0debe657e/benchmark/single-source/ChaCha.swift#L59). In this case, the ChaCha state is initialized using the contents of the collection "key" rather than "key" itself. NOTE: One thing to keep in mind with this example is that the optimizer completely inlines away the iterator so even though we use an iterator here. This results in the optimizer eliminating all of the ARC traffic from the usage of the CollectionOf32BitLittleEndianIntegers.makeIterator() causing the only remaining ARC traffic to be related to key being passed as an argument. Hence if we did not use shared, we would have an unnecessary release in init.
    ```swift
    init<Key: Collection, Nonce: Collection>(key: __shared Key, nonce: Nonce, counter: UInt32) where Key.Element == UInt8, Nonce.Element == UInt8 {
        /* snip */
        var keyIterator = CollectionOf32BitLittleEndianIntegers(key).makeIterator()
        self._state.4 = keyIterator.next()!
        self._state.5 = keyIterator.next()!
        self._state.6 = keyIterator.next()!
        /* snip */
    }
    ```
* Passing a consuming argument to a normal function or method that isn't a
  setter but acts like a setter.
    1. Implementing append on a collection. Example: [Array.append(_:)](https://github.com/apple/swift/blob/324cccd18e9297b3cea9fc88d1ce80a0debe657e/stdlib/public/core/Array.swift#L1167). In this example, we want to forward the element directly into memory without inserting a retain, so we must use the underscored attribute `__owned` to change the default convention to be consuming.
    ```swift
    public mutating func append(_ newElement: __owned Element) {
      // Separating uniqueness check and capacity check allows hoisting the
      // uniqueness check out of a loop.
      _makeUniqueAndReserveCapacityIfNotUnique()
      let oldCount = _buffer.mutableCount
      _reserveCapacityAssumingUniqueBuffer(oldCount: oldCount)
      _appendElementAssumeUniqueAndCapacity(oldCount, newElement: newElement)
      _endMutation()
    }
    ```
    2. Bridging APIs. Example: [_bridgeAnythingNonVerbatimToObjectiveC()](https://github.com/apple/swift/blob/324cccd18e9297b3cea9fc88d1ce80a0debe657e/stdlib/public/core/BridgeObjectiveC.swift#L216). In this case, we want to consume the object into its bridged representation so we do not have to copy when bridging.
    ```swift
    func _bridgeAnythingNonVerbatimToObjectiveC<T>(_ x: __owned T) -> AnyObject
    ```
* Consuming self when calling a method that is not an initializer.
    1. Creating an iterator for a collection. Example: [Collection.makeIterator()](https://github.com/apple/swift/blob/324cccd18e9297b3cea9fc88d1ce80a0debe657e/stdlib/public/core/Collection.swift#L1008). The iterator needs to have a reference to self so to reduce ARC traffic, we pass self into makeIterator at +1.
    ```swift
    extension Collection where Iterator == IndexingIterator<Self> {
      /// Returns an iterator over the elements of the collection.
      @inlinable
      public __consuming func makeIterator() -> IndexingIterator<Self> {
        return IndexingIterator(_elements: self)
      }
    }
    ```
    2. Sequence based algorithms that use iterators. Example: [Sequence.filter()](https://github.com/apple/swift/blob/324cccd18e9297b3cea9fc88d1ce80a0debe657e/stdlib/public/core/Sequence.swift#L678). In this case since we are using makeIterator, we need self to be __consuming.
    ```swift
      @inlinable
      public __consuming func filter(
        _ isIncluded: (Element) throws -> Bool
      ) rethrows -> [Element] {
        var result = ContiguousArray<Element>()

        var iterator = self.makeIterator()

        while let element = iterator.next() {
          if try isIncluded(element) {
            result.append(element)
          }
        }

        return Array(result)
      }
    ```

In all of the above cases, by using underscored attributes, authors changed the
default convention since it introduced extra copy/destroys.

## Proposed solution

As mentioned in the previous section, the compiler already internally supports
these semantics in the guise of underscored, source unstable keywords `__owned`,
`__shared` and for self the keyword `__consuming`. We propose that we:

1. Add two new keywords to the language: `consuming` and `nonconsuming`.

2. Make `consuming` a synonym for `__consuming` when using `__consuming` to make
   self a +1 argument.

3. On non-self arguments, make `consuming` a synonym for `__owned` and
   `nonconsuming` a synonym for `__shared`.

## Detailed design

We propose formally modifying the Swift grammar as follows:

```
// consuming, nonconsuming for parameters
- type-annotation → : attributes? inout? type
+ type-annotation → : attributes? type-modifiers? type
+ type-modifiers → : type-modifier type-modifier*
+ type-modifier → : inout
+               → : consuming
+               → : nonconsuming
+

// consuming for self
+ declaration-modifier → : consuming
```

The only work that is required is to add support to the compiler for accepting
the new spellings mentioned (`consuming` and `nonconsuming`) for the underscored
variants of those keywords.

## Source compatibility

Since we are just adding new spellings for things that already exist in the
compiler, this is additive and there isn't any source compatibility impact.

## Effect on ABI stability

This will not effect the ABI of any existing language features since all uses
that already use `__owned`, `__shared`, and `__consuming` will work just as
before. Applying `consuming`, `nonconsuming` to function arguments will result
in ABI break to existing functions if the specified convention does not match
the default convention.

## Effect on API resilience

Changing a argument from `consuming` to `nonconsuming` or vice versa is an
ABI-breaking change. Adding an annotation that matches the default convention
does not change the ABI.

## Alternatives considered

We could reuse `owned` and `shared` and just remove the underscores. This was
viewed as confusing since `shared` is used in other contexts since `shared` can
mean a rust like "shared borrow" which is a much stronger condition than
`nonconsuming` is. Additionally, since we already will be using `consuming` to
handle +1 for self, for consistency it makes sense to also rename `owned` to
`consuming`.

## Acknowledgments

Thanks to Robert Widmann for the original underscored implementation of
`__owned` and `__shared`: [https://forums.swift.org/t/ownership-annotations/11276](https://forums.swift.org/t/ownership-annotations/11276).
