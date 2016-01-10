# Feature name

* Proposal: TBD
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add a new stdlib function `replace(_:with:)` that swaps an inout property with a
value and returns the old value.

Swift-evolution thread: [Proposal: Add replace(_:with:) function to the stdlib](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/002149.html)

## Motivation

A fairly common task in Swift code is to replace the value of a property and
then do something with the previous value. In nearly every Swift project I work
on I find myself defining a function to handle this because it's convenient, and
I think it would be useful to have it in the standard library.

This function replaces the following idiom:

```swift
let oldValue = someProp
someProp = newValue
doSomethingWith(oldValue)
```

It also turns the following into one line:

```swift
doSomethingWith(someProp)
someProp = newValue
```

(assuming that it's valid to call `doSoemthingWith()` after mutating the
property, like in the previous example)

It also simplifies the following:

```swift
if let someValue = someProp {
    someProp = nil
    doSomethingWith(someValue)
}
```

In the future, if Swift ever gains move-only structs, then a function like this
will be even more useful, because handling this case without the function
requires copying the old value into a local property first (and you can't copy
move-only structs).

## Proposed solution

Add a function to the stdlib that looks like

```swift
/// Replace the value of `a` with `b` and return the old value.
public func replace<T>(inout a: T, with b: T) -> T
```

This function is pretty simple, and is basically the equivalent of performing a
`swap()` using an rvalue instead of an lvalue. We already have precedent in the
standard library for methods that mutate one value and return something else,
such as `Dictionary.updateValue(_:forKey:)`. `replace(_:with:)` can be thought
of as a generalization of `Dictionary.updateValue(_:forKey:)` for arbitrary
properties.

With this function, the examples given in Motivation can be rewritten like:

```swift
doSomethingWith(replace(&someProp, with: newValue))
```

and

```swift
if let someValue = replace(&someProp, with: nil) {
  doSomethingWith(someValue)
}
```

As a more concrete example, in the stdlib default implementation of
`SequenceType.dropLast(_:)`, the following code:

```swift
result.append(ringBuffer[i])
ringBuffer[i] = element
```

could be rewritten as:

```swift
result.append(replace(&ringBuffer[i], with: element))
```

Not only is this one line instead of two, but if Swift ever gains move-only
structs, this new version will work as-is on sequences of move-only structs.

This also works particularly elegantly with optional chaining, so you can say
things like:

```swift
replace(&task, with: nil)?.cancel()
```

## Detailed design

The implementation of the function looks like

```swift
/// Replace the value of `a` with `b` and return the old value.
public func replace<T>(inout a: T, with b: T) -> T {
  var value = b
  swap(&a, &value)
  return value
}
```

## Impact on existing code

None, this feature is purely additive.

## Alternatives considered

Define a new operator to perform this same task, such as `<-`, that would be
used like:

```swift
(&task <- nil)?.cancel()
```

However, I find this a bit clunky, and trying to actually implement this throws
a strange error on use ("reference to 'T' not used to initialize a inout
parameter").
