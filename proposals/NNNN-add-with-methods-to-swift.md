# Add `with` magic methods to Swift

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [aggie33](https://github.com/aggie33)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: **Awaiting implementation**
* Review: [Pitch](https://forums.swift.org/t/pitch-with-functions-in-the-standard-library/65716)

## Introduction

Add two `with(_:)` methods to Swift to allow for easier modification of values.

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

This might not seem too difficult, but it can become tedious and repetitive. Imagine if you were wrapping a UIKit view, such as UIButton.

```swift
struct SwiftyButton: UIViewRepresentable {
   private var role: UIButton.Role
   private var behavioralStyle: UIBehavioralStyle

   func makeUIView(...) -> UIButton { ... }
   func updateUIView(...) { ... }
}
```
For each modifier method, you need to repeat the same copying boilerplate.
```swift
extension SwiftyButton {
    func role(_ role: UIButton.Role) -> SwiftyButton {
        var copy = self
        copy.role = role
        return copy
    }

    func behavioralStyle(_ style: UIBehavioralStyle) -> SwiftyButton {
        var copy = self
        copy.behavioralStyle = style
        return copy
    }
}
```
This is tedious, and it hides what the method is actually doing. 2/3rds of each method is the same copying boilerplate. 

## Proposed solution

I propose we add two magic `with` methods to all types. These methods would take a copy of `self`, and a closure that modifies that copy. They would return the copy. The above code can be rewritten to be clearer and shorter with these methods.

``` swift
let components = URLComponents().with { components in
  components.path = "foo"
  components.password = "bar"
}
```

What this code does is clearer, because the value being modified is at the beginning instead of the end, and clutter is removed.
The SwiftUI view examples is also improved by these functions.

```swift
extension FooView {
  func bar() -> some View {
    self.with { $0.bar = true }
  }
}

extension SwiftyButton {
    func role(_ role: UIButton.Role) -> SwiftyButton {
        self.with { $0.role = role }
    }

    func behavioralStyle(_ style: UIBehavioralStyle) -> SwiftyButton {
        self.with { $0.behavioralStyle = style } 
    }
}
```

What previously took 3 lines now only takes one, and the code is just as clear.

This has already been adopted in various places. Some helper libraries introduce this as an extension method on `NSObjectProtocol`, and `SwiftSyntax` has a similar method available on its syntax nodes.

## Detailed design

We introduce two new methods on `Any` using compiler magic, both called `with(_:)`; a synchronous and asynchronous overload.
```swift
extension Any {
    /// Makes a copy of `self` and invokes `transform` on it, then returns the modified value.
    /// - Parameters:
    ///   - transform: The closure used to modify `self`.
    @inlinable // trivial implementation, generic
    public func with(transform: (inout Self) throws -> Void) rethrows -> Self {
        var copy = self
        try transform(&copy)
        return copy
    }
    
    /// Makes a copy of `self` and invokes `transform` on it, then returns the modified value.
    /// - Parameters:
    ///   - transform: The closure used to modify `self`.
    @inlinable // trivial implementation, generic
    public func with(transform: (inout Self) async throws -> Void) async rethrows -> Self {
        var copy = self
        try await transform(&copy)
        return copy
    }
}
```
## Source compatibility

This could result in a source-break if someone declared a method on their type with the same name and parameters; however, it seems likely that such a method would do the same thing as this one. If someone declared a with method using different parameters, and then made an unapplied reference to it:
```swift
let closure = foo.with // some closure type
// ...
closure(5, 6, 7)
```
That would cause source-break, as the reference would no longer be clear. However, this seems unlikely.

## ABI compatibility

This is a purely additive change, so it should not affect ABI compatibility.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Future directions

### Add `with` overloads that allow you to return a value inside of the closure
This would allow you to more easily use certain mutating methods that return a value.

### Allow arbitrary extensions on `Any`
This would allow anyone to easily write methods like this, or other helpers. For example, `print` could be made a method.
```swift
extension Any {
    func print() { Swift.print(self) }
}
```

## Alternatives considered

### Do nothing
This is a common problem, so I think we should do something.

### Use a `with` free function.
This was what was suggested in the initial version of this proposal. However, the `with` method was more popular with the Swift community.

### Use an operator instead of `with`.
While an operator would be terser, and wouldn't require compiler magic; it's less discoverable and might confuse new users. Also, the question would remain of what operator to use.

## Acknowledgments

N/A
