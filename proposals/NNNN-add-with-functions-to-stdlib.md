# Add `with` functions to the Standard Library

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [aggie33](https://github.com/aggie33)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swift#66806](https://github.com/apple/swift/pull/66806)
* Review: [Pitch](https://forums.swift.org/t/pitch-with-functions-in-the-standard-library/65716)

## Introduction

Add two `with(_:)` functions to the standard library to allow for easier modification of values.

## Motivation

It is common for swift APIs to require you to create a value, modify various properties on the value, and then return it. This requires you to declare it as a variable instead of a constant, even if this 'configuration' stage is the only time you modify the value. This is less ergonomic than creating and changing the value in one statement. Currently, doing this would require you to write a closure and make a copy inside of it, like this.

```swift
let components = {
    var copy = $0
    copy.path = "foo"
    copy.password = "bar"
    return copy
}(URLComponents())
```

Also, in some APIs, like in SwiftUI, it is common to want to make a simple modification to a copy of a value, and then return the copy. These functions would make this easier. Currently, you have to write code like this.

```swift
extension FooView { 
  func bar() -> some View {
    var copy = self
    copy.bar = true
    return copy
  }
}
```

## Proposed solution

Using the new `with` functions in this proposal, the two pieces of code above could be rewritten as follows.

``` swift
let components = with(URLComponents()) { components in
  components.path = "foo"
  components.password = "bar"
}
```

What this code does is clearer, because the value being modified is at the beginning instead of the end, and clutter is removed.
The SwiftUI view example is also improved by these functions.

```swift
extension FooView {
  func bar() -> some View {
    with(self) { $0.bar = true }
  }
}
```

What previously took 3 lines now only takes one, and the code is just as clear.

This has already been adopted in various places. Some helper libraries introduce this as an extension method on `NSObjectProtocol`, and `SwiftSyntax` has a similar method available on its syntax nodes.

## Detailed design

We introduce two new functions, both called `with(_:)`; a synchronous and asynchronous overload.
```swift
/// Makes a copy of `value` and invokes `transform` on it, then returns the modified value.
/// - Parameters:
///   - value: The value to modify.
///   - transform: The closure used to modify the value.
/// - Throws: An error, if the closure throws one.
/// - Returns: The modified value.
@inlinable // trivial implementation, generic
public func with<T>(_ value: T, transform: (inout T) throws -> Void) rethrows -> T {
    var copy = value
    try transform(&copy)
    return copy
}

/// Makes a copy of `value` and invokes `transform` on it, then returns the modified value.
/// - Parameters:
///   - value: The value to modify.
///   - transform: The closure used to modify the value.
/// - Throws: An error, if the closure throws one.
/// - Returns: The modified value.
@inlinable // trivial implementation, generic
public func with<T>(_ value: T, transform: (inout T) async throws -> Void) async rethrows -> T {
    var copy = value
    try await transform(&copy)
    return copy
}
```
## Source compatibility

This could result in a source-break if someone declared a free function named `with(_:)` with these parameters in their library; however due to the simple nature of this function, we think that a user-defined implementation would probably do the same thing. Also, user-defined functions are preferred over standard library functions, so this shouldn't be an issue.

## ABI compatibility

This is a purely additive change, so it should not affect ABI compatibility.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Future directions

### Add `with` as a magical extension on `Any`
This could potentially make it easier to use the `with` function, but is not necessary for this proposal.

### Add `with` overloads that allow you to return a value inside of the closure
This would allow you to more easily use certain mutating methods that return a value, but is not necessary for this proposal.

## Alternatives considered

### Do nothing
While this functionality could improve code, it is trivial and easy to add to a codebase. However, I think a fairly widely useful function like this belongs in the standard library.

### Make `with` a macro instead
This would allow the macro to expand to a simple closure, but it feels unnecessary considering this is easily implemented as a function.

### Use an operator instead of `with`
This could allow for terser syntax than `with(_:transform:)` and allow you to skip the parentheses, like this. 
```swift
NumberFormatter() &> {
  $0.numberStyle = .currency
}
```
However, I feel like introducing such a new operator to the standard library for this isn't necessary, and could cause source-break if anyone else defined this operator. There's also the question of which operator would be best to use.


## Acknowledgments

N/A
