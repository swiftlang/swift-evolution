# Add `isTriviallyIdentical(to:)` Methods for Quick Comparisons to Concrete Types

* Proposal: [SE-0494](0494-add-is-identical-methods.md)
* Authors: [Rick van Voorden](https://github.com/vanvoorden), [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Accepted with modifications**
* Implementation: [swift/issues/84991](https://github.com/swiftlang/swift/issues/84991)
* Review: ([prepitch](https://forums.swift.org/t/-/78792)) ([first pitch](https://forums.swift.org/t/-/79145)) ([second pitch](https://forums.swift.org/t/-/80496)) ([review](https://forums.swift.org/t/se-0494-add-isidentical-to-methods-for-quick-comparisons-to-concrete-types/82296)) ([revision](https://forums.swift.org/t/se-0494-add-isidentical-to-methods-for-quick-comparisons-to-concrete-types/82296/142)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0494-add-isidentical-to-methods-for-quick-comparison-to-concrete-types/82695))

### Table of Contents

  * [Introduction](#introduction)
  * [Motivation](#motivation)
  * [Prior Art](#prior-art)
  * [Proposed Solution](#proposed-solution)
  * [Detailed Design](#detailed-design)
    * [`String`](#string)
    * [`Substring`](#substring)
    * [`Array`](#array)
    * [`Dictionary`](#dictionary)
    * [`Set`](#set)
    * [`UnsafeBufferPointer`](#unsafebufferpointer)
    * [`UTF8Span`](#utf8span)
  * [Source Compatibility](#source-compatibility)
  * [Impact on ABI](#impact-on-abi)
  * [Future Directions](#future-directions)
  * [Alternatives Considered](#alternatives-considered)
    * [Exposing Identity](#exposing-identity)
    * [Different Names](#different-names)
    * [Generic Contexts](#generic-contexts)
    * [Overload for Reference Comparison](#overload-for-reference-comparison)
    * [Support for Optionals](#support-for-optionals)
    * [Alternative Semantics](#alternative-semantics)
  * [Acknowledgments](#acknowledgments)

## Introduction

We propose new `isTriviallyIdentical(to:)` instance methods to concrete types for quickly determining if two instances must be equal by-value.

## Motivation

Suppose we need an algorithm that transforms an `Array` of `Int` values to select only the even numbers:

```swift
func result(for input: [Int]) -> [Int] {
  print("computing new result")
  return input.filter {
    $0 % 2 == 0
  }
}
```

This produces a correct answer… but what about performance? We expect our `result` function to run in `O(n)` time across the size of our `input` value. Suppose we need for this algorithm to be called *many* times over the course of our application. It might also be the case that we sometimes call this algorithm with the same `input` value more than once:

```swift
let a = [1, 2, 3, 4]
print(result(for: a))
// Prints "computing new result"
// Prints "[2, 4]"
let b = a
print(result(for: b))
// Prints "computing new result"
// Prints "[2, 4]"
let c = [1, 2, 3, 4]
print(result(for: c))
// Prints "computing new result"
// Prints "[2, 4]"
let d = [1, 2, 3, 4, 5, 6]
print(result(for: d))
// Prints "computing new result"
// Prints "[2, 4, 6]"
let e = d
print(result(for: e))
// Prints "computing new result"
// Prints "[2, 4, 6]"
let f = [1, 2, 3, 4, 5, 6]
print(result(for: f))
// Prints "computing new result"
// Prints "[2, 4, 6]"
```

If we call our `result` function with an `Array` of values and then pass the same `Array` of values again, we might want to return our previous `result` *without* performing another `O(n)` operation. Because our `result` function is a pure function and free of side-effects, we can check the new `input` value against the last `input` value we used to compute our `result`. If the `input` values have not changed, the `result` value *also* must not have changed.

Here is an attempt to *memoize* our `result`:

```swift
final class Memoizer {
  private var input: [Int]?
  private var result: [Int]?
  
  func result(for input: [Int]) -> [Int] {
    if let result = self.result,
       self.input == input {
      return result
    } else {
      print("computing new result")
      self.input = input
      let result = input.filter {
        $0 % 2 == 0
      }
      self.result = result
      return result
    }
  }
}
```

When we pass `input` values we can see that a new `result` is not computed if we already computed a `result` for those same `input` values:

```swift
let memoizer = Memoizer()
let a = [1, 2, 3, 4]
print(memoizer.result(for: a))
// Prints "computing new result"
// Prints "[2, 4]"
let b = a
print(memoizer.result(for: b))
// Prints "[2, 4]"
let c = [1, 2, 3, 4]
print(memoizer.result(for: c))
// Prints "[2, 4]"
let d = [1, 2, 3, 4, 5, 6]
print(memoizer.result(for: d))
// Prints "computing new result"
// Prints "[2, 4, 6]"
let e = d
print(memoizer.result(for: e))
// Prints "[2, 4, 6]"
let f = [1, 2, 3, 4, 5, 6]
print(memoizer.result(for: f))
// Prints "[2, 4, 6]"
```

This looks like a big improvement… until we begin to investigate a little closer. There’s a subtle performance bottleneck here now from a different direction. Our memoization algorithm depends on the value equality of our `input` values — and this is *also* an `O(n)` operation. So while it is true that we have reduced the amount of `O(n)` operations that take place to compute our `result` values, we have *added* `O(n)` operations to determine value equality. As the amount of time spent computing value equality grows, we might no longer see any performance wins from memoization: it would be cheaper to just go ahead and compute a new `result` every time.

Let’s see another example. Suppose we are working on our SwiftUI app to display Contacts from [SE-0261](0261-identifiable.md). Let’s begin with our basic data model:

```swift
struct Contact: Identifiable, Equatable {
  let id: Int
  var name: String
  var isFavorite: Bool
}
```

We added an `isFavorite` property to indicate our user added this `Contact` value as one of their favorites.

Here is a SwiftUI view component that displays our favorite `Contact` values in a `FavoriteContactList`:

```swift
struct FavoriteContactList: View {
  @State private var selection: Contact.ID?
  
  private let contacts: [Contact]
  
  init(_ contacts: [Contact]) {
    self.contacts = contacts
  }
  
  private var favorites: [Contact] {
    self.contacts.filter {
      $0.isFavorite
    }
  }
  
  var body: some View {
    List(self.favorites, selection: self.$selection) { contact in
      FavoriteCell(contact)
    }
  }
}
```

We can assume there is another view component in our application that could be editing these `Contact` values. It's not very important for us right now to show *how* these `Contact` values could change — let's just assume that our `FavoriteContactList` component might need to recompute its `body` over time with new `Contact` values.

When we compute our `body` property we also compute our `favorites` property. The implication is that *every* time our `body` property is computed we perform *another* `O(n)` algorithm across our `contacts`. Because our `FavoriteContactList` supports selection, every time our user selects a `Contact` value we update our `State`. Updating our `State` computes our `body` which computes our `favorites` property. So even though our `contacts` values *have not changed*, we *still* pay the performance penalty of *another* `O(n)` operation just to support cell selection.

This might look like a good opportunity for another attempt at memoization. Here is an approach using a dynamic property wrapper:

```swift
@propertyWrapper struct Favorites: DynamicProperty {
  @State private var storage: Storage
  private let contacts: [Contact]
  
  init(_ contacts: [Contact]) {
    self.storage = Storage(contacts)
    self.contacts = contacts
  }
  
  func update() {
    self.storage.update(self.contacts)
  }
  
  var wrappedValue: [Contact] {
    self.storage.wrappedValue
  }
}

extension Favorites {
  private final class Storage {
    private var contacts: [Contact]
    private var favorites: [Contact]?
    
    init(_ contacts: [Contact]) {
      self.contacts = contacts
      self.favorites = nil
    }
    
    func update(_ contacts: [Contact]) {
      if self.contacts != contacts {
        self.contacts = contacts
        self.favorites = nil
      }
    }
    
    var wrappedValue: [Contact] {
      if let favorites = self.favorites {
        return favorites
      }
      print("computing new result")
      let favorites = self.contacts.filter {
        $0.isFavorite
      }
      self.favorites = favorites
      return favorites
    }
  }
}
```

Here is what that looks like used from our `FavoriteContactList`:

```swift
struct FavoriteContactList: View {
  @State private var selection: Contact.ID?
  
  @Favorites private var favorites: [Contact]
  
  init(_ contacts: [Contact]) {
    self._favorites = Favorites(contacts)
  }
  
  var body: some View {
    List(self.favorites, selection: self.$selection) { contact in
      FavoriteCell(contact)
    }
  }
}
```

When we build and run our app we see that we no longer compute our `favorites` values every time our user selects a new `Contact`. But similar to what we saw in our command line utility, we have traded performance in a different direction. The value equality operation we perform is *also* `O(n)`. As the amount of time we spend computing value equality grows, we can begin to spend more time computing value equality than we would have spent computing our `favorites`: we no longer see the performance benefits of memoization.

This proposal introduces an advanced performance hook for situations like this: a set of `isTriviallyIdentical(to:)` methods that are designed to return *faster* than an operation to determine value equality. The `isTriviallyIdentical(to:)` methods can return `true` in `O(1)` to indicate two values *must* be equal.

## Prior Art

We said that the performance of the value equality operator on an `Array` value was `O(n)`. This is true in the *worst case*, but there does exist an important “fast path” that can return `true` in constant time.

Many types in Standard Library are “copy-on-write” data structures. These types present as value types, but can leverage a reference to some shared state to optimize for performance. When we copy this value we copy a reference to shared storage. If we perform a mutation on a copy we can preserve value semantics by copying the storage reference to a unique value before we write our mutation: we “copy” on “write”.

This means that many types in Standard Library already have some private reference that can be checked in constant time to determine if two values are identical. Because these types copy before writing, two values that are identical by their shared storage *must* be equal by value. What we propose here is a way to “expose” this fast path operation.

Product engineers have evolved patterns over the years that can already come close to what we are proposing. Product engineers building on `Array` can use `withUnsafeBufferPointer` or `withContiguousStorageIfAvailable` to compare the “identity” of two `Array` values. One drawback here is that these are only guaranteed to return an identity in constant time if there already exists a contiguous storage. If there does *not* exist a contiguous storage, we might have to perform an `O(n)` algorithm — which defeats the purpose of us choosing this as a fast path. Another option might be `withUnsafeBytes`, but this carries some restrictions on the `Element` of our `Array` and also might require for a contiguous storage to be created: an `O(n)` algorithm.

Even if we were able to use `withUnsafeBytes` for other data structures, a comparison using `memcmp` might compare “unnecessary” bits that do not affect the identity. This slows down our algorithm and also returns “false negatives”: returning `false` when these instances should be treated as identical.

A solution for modern operating systems is the support we added from [SE-0456](0456-stdlib-span-properties.md) to bridge an `Array` to `Span`. We can then compare these instances using the `isIdentical(to:)` method on `Span`. One drawback here is that we are blocked on back-deploying support for bridging `Array` to `Span`: it is only available on the most modern operating systems. Another drawback is that if our `Array` does not have a contiguous storage, we have to copy one: an `O(n)` operation. We are also blocked on bringing support for `Span` to collection types like `Dictionary` that do not already implement contiguous storage.

A new `isTriviallyIdentical(to:)` method could work around all these restrictions. We could return in constant time *without* needing to copy memory to a contiguous storage. We could adopt this method on many types that might not *ever* have a contiguous storage. We could also work with our library maintainers to discuss a back-deployment strategy that could bring this method to legacy operating systems.

`String` already ships a public-but-underscored version of this API.[^1]

```swift
extension String {
  /// Returns a boolean value indicating whether this string is identical to
  /// `other`.
  ///
  /// Two string values are identical if there is no way to distinguish between
  /// them.
  ///
  /// Comparing strings this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// string storage object. Therefore, identical strings are guaranteed to
  /// compare equal with `==`, but not all equal strings are considered
  /// identical.
  ///
  /// - Performance: O(1)
  @_alwaysEmitIntoClient
  public func _isIdentical(to other: Self) -> Bool {
    self._guts.rawBits == other._guts.rawBits
  }
}
```

We don’t see this API currently being used in Standard Library, but it’s possible this API is already being used to optimize performance in private frameworks from Apple.

Many more examples of `isIdentical(to:)` functions are currently shipping in `Swift-Collections`[^2][^3][^4][^5][^6][^7][^8][^9][^10][^11][^12][^13], `Swift-Markdown`[^14], and `Swift-CowBox`[^15]. We also support `isIdentical(to:)` on the `Span` and `RawSpan` types from Standard Library.[^16]

## Proposed Solution

Before we look at the concrete types in this proposal, let’s begin with some more general principles and ideas we would expect for *all* concrete types to follow when adopting this new method. While this specific proposal is not adding a new protocol to Standard Library, it could be helpful to think of an “informal” protocol that guides us in choosing the types to adopt this new method. This could then serve as a guide for library maintainers that might choose to adopt this method on *new* types in the future.

Suppose we are proposing an `isTriviallyIdentical(to:)` method on a type `T`. We propose the following axioms that library maintainers should adopt:

* `a.isTriviallyIdentical(to: a)` is always `true` (Reflexivity)
* If `T` is `Equatable`:
  * `a.isTriviallyIdentical(to: b)` implies `a == b` (*or else `a` and `b` are exceptional values*)
  * `isTriviallyIdentical(to:)` is *meaningfully* faster than `==`

Let’s look through these axioms a little closer:

**`a.isTriviallyIdentical(to: a)` is always `true` (Reflexivity)**

* An implementation of `isTriviallyIdentical(to:)` that always returns `false` would not be an impactful API. We must guarantee that `isTriviallyIdentical(to:)` *can* return `true` at least *some* of the time.

**If `T` is `Equatable` then `a.isTriviallyIdentical(to: b)` implies `a == b`**

* This is the “fast path” performance optimization that will speed up the memoization examples we saw earlier. One important side effect here is that when `a.isTriviallyIdentical(to: b)` returns `false` we make *no* guarantees about whether or not `a` is equal to `b`.
* We assume this axiom holds only if `a` and `b` are not “exceptional” values. A example of an exceptional value would be if a container that is generic over `Float` contains `nan`.

**If `T` is `Equatable` then `isTriviallyIdentical(to:)` is *meaningfully* faster than `==`**

* While we could implement `isTriviallyIdentical(to:)` on types like `Int` or `Bool`, these types are not included in this proposal. Our proposal focuses on types that have the ability to return from `isTriviallyIdentical(to:)` meaningfully faster than `==`. If a type would perform the same amount of work in `isTriviallyIdentical(to:)` that takes place in `==`, our advice is that library maintainers should *not* adopt `isTriviallyIdentical(to:)` on this type. There should exist some legit internal fast-path on this type: like a pointer to a storage buffer that can be compared by reference identity.

This proposal focuses on concrete types that are `Equatable`, but it might also be the case that a library maintainer would adopt `isTriviallyIdentical(to:)` on a type that is *not* `Equatable`: like `Span`. Our expectation is that a library maintainer adopting  `isTriviallyIdentical(to:)`on a type that is not `Equatable` has some strong and impactful real-world use-cases ready to make use of this API. Just because a library maintainer *can* adopt this API does not imply they *should*. A library maintainer should also be ready to document for product engineers exactly what is implied from `a.isTriviallyIdentical(to: b)` returning `true`. What does it *mean* for `a` to be “identical” to `b` if we do not have the implication that `a == b`? We leave this decision to the library maintainers that have the most context on the types they have built.

Suppose we had an `isTriviallyIdentical(to:)` method available on `Array`. Let’s go back to our earlier example and see how we can use this as an alternative to checking for value equality from our command line utility:

```swift
final class Memoizer {
  ...
  
  func result(for input: [Int]) -> [Int] {
    if let result = self.result,
       self.input.isTriviallyIdentical(to: input) {
      return result
    } else {
      ...
    }
  }
}
```

We can run our previous example and confirm that we are not computing new results when the input has not changed:

```swift
let memoizer = Memoizer()
let a = [1, 2, 3, 4]
print(memoizer.result(for: a))
// Prints "computing new result"
// Prints "[2, 4]"
let b = a
print(memoizer.result(for: b))
// Prints "[2, 4]"
let c = [1, 2, 3, 4]
print(memoizer.result(for: c))
// Prints "computing new result"
// Prints "[2, 4]"
let d = [1, 2, 3, 4, 5, 6]
print(memoizer.result(for: d))
// Prints "computing new result"
// Prints "[2, 4, 6]"
let e = d
print(memoizer.result(for: e))
// Prints "[2, 4, 6]"
let f = [1, 2, 3, 4, 5, 6]
print(memoizer.result(for: f))
// Prints "computing new result"
// Prints "[2, 4, 6]"
```

When we return `true` from `isTriviallyIdentical(to:)` we skip computing a new `result`. When `isTriviallyIdentical(to:)` returns `false` we compute a new `result`. Because `isTriviallyIdentical(to:)` *can* return `false` when two values are equal, we might be computing the same `result` more than once. The performance tradeoff is that because the operation to compute a new `result` is `O(n)` time, we might not *want* to perform another `O(n)` value equality operation to determine if we should compute a new `result`. Our `isTriviallyIdentical(to:)` will return in constant time no matter how many elements are in `input` or how expensive this value equality operation would be.

Let’s go back to our SwiftUI app for displaying `Contact` values. Here is what the change would look like to use `isTriviallyIdentical(to:)` in place of value equality to memoize `favorites`:

```swift
extension Favorites {
  private final class Storage {
    ...
    
    func update(_ contacts: [Contact]) {
      if self.contacts.isTriviallyIdentical(to: contacts) == false {
        self.contacts = contacts
        self.favorites = nil
      }
    }
    
    ...
  }
}
```

When we build and run our SwiftUI app we confirm that we are not computing new `favorites` when the user selects new `Contact` values from `FavoriteContactList`.

## Detailed Design

We propose adding `isTriviallyIdentical(to:)` methods to the following concrete types from Standard Library:

* `String`
* `String.UnicodeScalarView`
* `String.UTF16View`
* `String.UTF8View`
* `Substring`
* `Substring.UnicodeScalarView`
* `Substring.UTF16View`
* `Substring.UTF8View`
* `Array`
* `ArraySlice`
* `ContiguousArray`
* `Dictionary`
* `Set`
* `UnsafeBufferPointer`
* `UnsafeMutableBufferPointer`
* `UnsafeMutableRawBufferPointer`
* `UnsafeRawBufferPointer`
* `UTF8Span`
* `Span`
* `RawSpan`

For each type being presented we codify important semantics in our header documentation.

### `String`

```swift
extension String {
  /// Returns a boolean value indicating whether this string is identical to `other`.
  ///
  /// Two string values are identical if there is no way to distinguish between them.
  /// 
  /// For any values `a`, `b`, and `c`:
  ///
  /// - `a.isTriviallyIdentical(to: a)` is always `true`. (Reflexivity)
  /// - `a.isTriviallyIdentical(to: b)` implies `b.isTriviallyIdentical(to: a)`. (Symmetry)
  /// - If `a.isTriviallyIdentical(to: b)` and `b.isTriviallyIdentical(to: c)` are both `true`, then `a.isTriviallyIdentical(to: c)` is also `true`. (Transitivity)
  /// - `a.isTriviallyIdentical(b)` implies `a == b`
  ///   - `a == b` does not imply `a.isTriviallyIdentical(b)`
  ///
  /// Values produced by copying the same value, with no intervening mutations, will compare identical:
  ///
  /// ```swift
  /// let d = c
  /// print(c.isTriviallyIdentical(to: d))
  /// // Prints true
  /// ```
  ///
  /// Comparing strings this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// string storage object. Therefore, identical strings are guaranteed to
  /// compare equal with `==`, but not all equal strings are considered
  /// identical.
  ///
  /// - Performance: O(1)
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

The following types will adopt `isTriviallyIdentical(to:)` with the same semantic guarantees as `String`:

* `String.UnicodeScalarView`
* `String.UTF16View`
* `String.UTF8View`

### `Substring`

```swift
extension Substring {
  /// Returns a boolean value indicating whether this substring is identical to `other`.
  ///
  /// Two substring values are identical if there is no way to distinguish between them.
  /// 
  /// For any values `a`, `b`, and `c`:
  ///
  /// - `a.isTriviallyIdentical(to: a)` is always `true`. (Reflexivity)
  /// - `a.isTriviallyIdentical(to: b)` implies `b.isTriviallyIdentical(to: a)`. (Symmetry)
  /// - If `a.isTriviallyIdentical(to: b)` and `b.isTriviallyIdentical(to: c)` are both `true`, then `a.isTriviallyIdentical(to: c)` is also `true`. (Transitivity)
  /// - `a.isTriviallyIdentical(b)` implies `a == b`
  ///   - `a == b` does not imply `a.isTriviallyIdentical(b)`
  ///
  /// Values produced by copying the same value, with no intervening mutations, will compare identical:
  ///
  /// ```swift
  /// let d = c
  /// print(c.isTriviallyIdentical(to: d))
  /// // Prints true
  /// ```
  ///
  /// Comparing substrings this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// substring storage object. Therefore, identical substrings are guaranteed
  /// to compare equal with `==`, but not all equal substrings are considered
  /// identical.
  ///
  /// - Performance: O(1)
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

The following types will adopt `isTriviallyIdentical(to:)` with the same semantic guarantees as `Substring`:

* `Substring.UnicodeScalarView`
* `Substring.UTF16View`
* `Substring.UTF8View`

### `Array`

```swift
extension Array {
  /// Returns a boolean value indicating whether this array is identical to `other`.
  ///
  /// Two array values are identical if there is no way to distinguish between them.
  /// 
  /// For any values `a`, `b`, and `c`:
  ///
  /// - `a.isTriviallyIdentical(to: a)` is always `true`. (Reflexivity)
  /// - `a.isTriviallyIdentical(to: b)` implies `b.isTriviallyIdentical(to: a)`. (Symmetry)
  /// - If `a.isTriviallyIdentical(to: b)` and `b.isTriviallyIdentical(to: c)` are both `true`, then `a.isTriviallyIdentical(to: c)` is also `true`. (Transitivity)
  /// - If `a` and `b` are `Equatable`, then `a.isTriviallyIdentical(b)` implies `a == b`
  ///   - `a == b` does not imply `a.isTriviallyIdentical(b)`
  ///
  /// Values produced by copying the same value, with no intervening mutations, will compare identical:
  ///
  /// ```swift
  /// let d = c
  /// print(c.isTriviallyIdentical(to: d))
  /// // Prints true
  /// ```
  ///
  /// Comparing arrays this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// array storage object. Therefore, identical arrays are guaranteed to
  /// compare equal with `==`, but not all equal arrays are considered
  /// identical.
  ///
  /// - Performance: O(1)
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

The following types will adopt `isTriviallyIdentical(to:)` with the same semantic guarantees as `Array`:

* `ArraySlice`
* `ContiguousArray`

### `Dictionary`

```swift
extension Dictionary {
  /// Returns a boolean value indicating whether this dictionary is identical to `other`.
  ///
  /// Two dictionary values are identical if there is no way to distinguish between them.
  ///
  /// For any values `a`, `b`, and `c`:
  ///
  /// - `a.isTriviallyIdentical(to: a)` is always `true`. (Reflexivity)
  /// - `a.isTriviallyIdentical(to: b)` implies `b.isTriviallyIdentical(to: a)`. (Symmetry)
  /// - If `a.isTriviallyIdentical(to: b)` and `b.isTriviallyIdentical(to: c)` are both `true`, then `a.isTriviallyIdentical(to: c)` is also `true`. (Transitivity)
  /// - If `a` and `b` are `Equatable`, then `a.isTriviallyIdentical(b)` implies `a == b`
  ///   - `a == b` does not imply `a.isTriviallyIdentical(b)`
  ///
  /// Values produced by copying the same value, with no intervening mutations, will compare identical:
  ///
  /// ```swift
  /// let d = c
  /// print(c.isTriviallyIdentical(to: d))
  /// // Prints true
  /// ```
  /// 
  /// Comparing dictionaries this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// dictionary storage object. Therefore, identical dictionaries are
  /// guaranteed to compare equal with `==`, but not all equal dictionaries are
  /// considered identical.
  ///
  /// - Performance: O(1)
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

### `Set`

```swift
extension Set {
  /// Returns a boolean value indicating whether this set is identical to `other`.
  ///
  /// Two set values are identical if there is no way to distinguish between them.
  /// 
  /// For any values `a`, `b`, and `c`:
  ///
  /// - `a.isTriviallyIdentical(to: a)` is always `true`. (Reflexivity)
  /// - `a.isTriviallyIdentical(to: b)` implies `b.isTriviallyIdentical(to: a)`. (Symmetry)
  /// - If `a.isTriviallyIdentical(to: b)` and `b.isTriviallyIdentical(to: c)` are both `true`, then `a.isTriviallyIdentical(to: c)` is also `true`. (Transitivity)
  /// - `a.isTriviallyIdentical(b)` implies `a == b`
  ///   - `a == b` does not imply `a.isTriviallyIdentical(b)`
  ///
  /// Values produced by copying the same value, with no intervening mutations, will compare identical:
  ///
  /// ```swift
  /// let d = c
  /// print(c.isTriviallyIdentical(to: d))
  /// // Prints true
  /// ```
  ///
  /// Comparing sets this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying set
  /// storage object. Therefore, identical sets are guaranteed to compare equal
  /// with `==`, but not all equal sets are considered identical.
  ///
  /// - Performance: O(1)
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

### `UnsafeBufferPointer`

```swift
extension UnsafeBufferPointer where Element: ~Copyable {
  /// Returns a Boolean value indicating whether two `UnsafeBufferPointer` instances refer to the same region in memory.
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
}
```

The following types will adopt `isTriviallyIdentical(to:)` with the same semantic guarantees as `UnsafeBufferPointer`:

* `UnsafeMutableBufferPointer`
* `UnsafeMutableRawBufferPointer`
* `UnsafeRawBufferPointer`

### `UTF8Span`

```swift
extension UTF8Span where Element: ~Copyable {
  /// Returns a Boolean value indicating whether two `UTF8Span` instances refer to the same region in memory.
  public func isTriviallyIdentical(to other: Self) -> Bool { ... }
```

The following types will adopt `isTriviallyIdentical(to:)` with the same semantic guarantees as `UTF8Span`:

* `Span`
* `RawSpan`

## Source Compatibility

This proposal is additive and source-compatible with existing code.

## Impact on ABI

This proposal is additive and ABI-compatible with existing code.

## Future Directions

Any Standard Library types that are copy-on-write values could be good candidates to add `isTriviallyIdentical(to:)` functions. Here are some potential types to consider for a future proposal:

* `Character`
* `Dictionary.Keys`
* `Dictionary.Values`
* `KeyValuePairs`
* `StaticBigInt`
* `StaticString`

This proposal focuses on what we see as the most high-impact types to support from Standard Library. This proposal *is not* meant to discourage adding `isTriviallyIdentical(to:)` on any of these types at some point in the future. A follow-up “second-round” proposal could focus on these remaining types.

## Alternatives Considered

### Exposing Identity

Our proposal introduces a new instance method on types that uses some underlying concept of “identity” to perform quick comparisons between two instances. A different approach would be to *return* the underlying identity to product engineers. If a product engineer wanted to test two instances for equality by identity they could perform that check themselves.

There’s a lot of interesting directions to go with that idea… but we don’t think this is right approach for now. Introducing some concept of an “escapable” identity to value types like `Array` would require *a lot* of design. It’s overthinking the problem and solving for something we don’t need right now.

### Different Names

Multiple different names have been suggested for these operations. Including:

* `isIdentical(to:)`
* `hasSameRepresentation(as:)`
* `isKnownIdentical(to:)`

### Generic Contexts

We proposed an “informal” protocol for library maintainers adopting `isTriviallyIdentical(to:)` on new types. Could we just build a new protocol in Standard Library? Maybe. We don’t see a big need for this right now. If product engineers would want for these types to conform to some common protocol to use across generic contexts, those product engineers can define that protocol in their own packages. If these protocols “incubate” in the community and become a common practice, we can consider proposing a new protocol in Standard Library.

Instead of a new protocol, could we somehow add `isTriviallyIdentical(to:)` on `Equatable`? Maybe. This would introduce some more tricky questions. If we adopt this on *all* `Equatable` types, what do we do about types like `Int` or `Bool` that do not have an ability to perform a fast check for identity? Similar to our last idea, we prefer to focus just on concrete types for now. If product engineers want to make `isTriviallyIdentical(to:)` available on generic contexts across `Equatable`, we encourage them to experiment with their own extension for that. If this pattern becomes popular in the community, we can consider a new proposal to add this on `Equatable` in Standard Library.

### Overload for Reference Comparison

Could we “overload” the `===` operator from `AnyObject`? This proposal considers that question to be orthogonal to our goal of exposing identity equality with the `isTriviallyIdentical(to:)` methods. We could choose to overload `===`, but this would be a larger “conceptual” and “philosophical” change because the `===` operator is currently meant for `AnyObject` types — not value types like `Array`.

### Support for Optionals

We can support `Optional` values with the following extension:

```swift
extension Optional {
  public func isTriviallyIdentical<T>(to other: Self) -> Bool
  where Wrapped == Array<T> {
    switch (self, other) {
    case let (value?, other?):
      return value.isTriviallyIdentical(to: other)
    case (nil, nil):
      return true
    default:
      return false
    }
  }
}
```

Because this extension needs no `private` or `internal` symbols from Standard Library, we can omit this extension from our proposal. Product engineers that want this extension can choose to implement it for themselves.

### Alternative Semantics

Instead of publishing an `isTriviallyIdentical(to:)` method which implies two types *must* be equal, could we think of things from the opposite direction? Could we publish a `maybeDifferent` method which implies two types *might not* be equal? This then introduces some potential ambiguity for product engineers: to what extent does “maybe different” imply “probably different”? This ambiguity could be settled with extra documentation on the method, but `isTriviallyIdentical(to:)` solves that ambiguity up-front. The `isTriviallyIdentical(to:)` method is also consistent with the prior art in this space.

In the same way this proposal exposes a way to quickly check if two values *must* be equal, product engineers might want a way to quickly check if two values *must not* be equal. This is an interesting idea, but this can exist as an independent proposal. We don’t need to block the review of this proposal on a review of `isNotIdentical` semantics.

## Acknowledgments

Thanks to [Ben Cohen](https://forums.swift.org/t/-/78792/7) for helping to think through and generalize the original use-case and problem-statement.

Thanks to [David Nadoba](https://forums.swift.org/t/-/80496/61/) for proposing the formal equivalence relation semantics and axioms on concrete types.

Thanks to [Xiaodi Wu](https://forums.swift.org/t/-/80496/67) for proposing that our equivalence relation semantics would carve-out for “exceptional” values like `Float.nan`.

Thanks to [QuinceyMorris](https://forums.swift.org/t/-/82296/72) for proposing the name `isTriviallyIdentical(to:)`.

Thanks to [benrimmington](https://github.com/swiftlang/swift/pull/84998) for volunteering to contribute implementations.

Thanks to [WindowsMEMZ](https://github.com/swiftlang/swift/pull/85171) for volunteering to contribute implementations.

[^1]: <https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/stdlib/public/core/String.swift#L397-L415>
[^2]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/DequeModule/Deque._Storage.swift#L223-L225>
[^3]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/HashTreeCollections/HashNode/_HashNode.swift#L78-L80>
[^4]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/HashTreeCollections/HashNode/_RawHashNode.swift#L50-L52>
[^5]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Conformances/BigString%2BEquatable.swift#L14-L16>
[^6]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUnicodeScalarView.swift#L77-L79>
[^7]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUTF8View.swift#L39-L41>
[^8]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUTF16View.swift#L39-L41>
[^9]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring.swift#L100-L103>
[^10]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUnicodeScalarView.swift#L94-L97>
[^11]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUTF8View.swift#L64-L67>
[^12]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUTF16View.swift#L87-L90>
[^13]: <https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/Rope/Basics/Rope.swift#L68-L70>
[^14]: <https://github.com/swiftlang/swift-markdown/blob/swift-6.1.1-RELEASE/Sources/Markdown/Base/Markup.swift#L370-L372>
[^15]: <https://github.com/Swift-CowBox/Swift-CowBox/blob/1.1.0/Sources/CowBox/CowBox.swift#L19-L27>
[^16]: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md>
