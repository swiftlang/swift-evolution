# Introducing `with` to the Standard Library

* Proposal: TBD
* Author: [Erica Sadun](https://github.com/erica), [Brent Royal-Gordon](https://github.com/brentdax)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal introduces a `with` function to the standard library. This function
simplifies the initialization of objects and modification of value types.

Swift-evolution thread:
[What about a VBA style with Statement?](http://thread.gmane.org/gmane.comp.lang.swift.evolution/14384)

## Motivation

When setting up or modifying an instance, developers sometimes use an 
immediately-called closure to introduce a short alias for the instance 
and group the modification code together. For example, they may 
initialize and customize a Cocoa object:

```swift
let questionLabel: UILabel = {
    $0.textAlignment = .Center
    $0.font = UIFont(name: "DnealianManuscript", size: 72)
    $0.text = questionText
    $0.numberOfLines = 0
    mainView.addSubview($0)
    return $0
}(UILabel())
```

Or they may duplicate and modify a constant value-typed instance:

```swift
let john = Person(name: "John", favoriteColor: .blueColor())
let jane: Person = { (var copy) in
    copy.name = "Jane"
    return copy
}(john)
```

This technique has many drawbacks:

* The compiler cannot infer the return type.
* You must explicitly `return` the modified instance.
* The instance being used comes after, not before, the code using it.

Nevertheless, developers have created many variations on this theme,
because they are drawn to its benefits:

* The short, temporary name reduces noise compared to repeating a 
  variable name like `questionLabel`.
* The block groups together the initialization code.
* The scope of mutability is limited.

[SE-0003, which removes `var` parameters](https://github.com/apple/swift-evolution/blob/master/proposals/0003-remove-var-parameters.md), 
will make this situation even worse by requiring a second line of 
boilerplate for value types. And yet developers will probably keep 
using these sorts of tricks.

Fundamentally, this is a very simple and common pattern: creating a 
temporary mutable variable confined to a short scope, whose value will 
later be used immutably in a wider scope. Moreover, this pattern 
shortens the scopes of mutable variables, so it is something we should 
encourage. We believe it's worth codifying in the standard library.

## Proposed Solution

We propose introducing a function with the following simplified signature:

```swift
func with<T>(_: T, update: (inout T -> Void)) -> T
```

`with` assigns the value to a new 
variable, passes that variable as a parameter to the closure, and 
then returns the potentially modified variable. That means:

* When used with value types, the closure can modify a copy of the original 
  value.
* When used with reference types, the closure can substitute a different
  instance for the original, perhaps by calling `copy()` or some non-Cocoa 
  equivalent.

The closure does not actually have to modify the parameter; it can 
merely use it, or (for a reference type) modify the object without 
changing the reference.

### Examples

#### Initializing a Cocoa Object

Before:

```swift
let questionLabel: UILabel = {
    $0.textAlignment = .Center
    $0.font = UIFont(name: "DnealianManuscript", size: 72)
    $0.text = questionText
    $0.numberOfLines = 0
    mainView.addSubview($0)
    return $0
}(UILabel())
```

After:

```swift
let questionLabel = with(UILabel()) {
    $0.textAlignment = .Center
    $0.font = UIFont(name: "DnealianManuscript", size: 72)
    $0.text = questionText
    $0.numberOfLines = 0
    mainView.addSubview($0)
}
```

Using `with` here moves the `UILabel()` initialization to the top, 
allows the type of `questionLabel` to be inferred, and removes the 
`return` statement.

#### Copying and Modifying a Constant

Before (without `var` parameter):

```swift
let john = Person(name: "John", favoriteColor: .blueColor())
let jane: Person = {
    var copy = $0
    copy.name = "Jane"
    return copy
}(john)
```

After:

```swift
let john = Person(name: "John", favoriteColor: .blueColor())
let jane = with(john) {
    $0.name = "Jane"
}
```

In addition to the aforementioned benefits, `with` removes the 
`var copy` line.

#### Treating a Mutable Method As a Copy-and-Return Method

You would like to write this:

```swift
let fewerFoos = foos.removing(at: i)
```

But there is only a `remove(at:)` mutating method. Using `with`, you can write:

```swift
let fewerFoos = with(foos) { $0.remove(at: i) }
```

#### Avoiding Mutable Shadowing

[The standard library includes an operator](https://github.com/apple/swift/blob/690d98a078a214557cd8f731b6215336bbc18a77/stdlib/public/core/RangeReplaceableCollection.swift.gyb#L1169)
 for concatenating two `RangeReplaceableCollection`s with this implementation:

```swift
var lhs = lhs
// FIXME: what if lhs is a reference type?  This will mutate it.
lhs.reserveCapacity(lhs.count + numericCast(rhs.count))
lhs.append(contentsOf: rhs)
return lhs
```

Using `with`, you can eliminate the shadowing of `lhs`:

```swift
// FIXME: what if lhs is a reference type?  This will mutate it.
return with(lhs) {
  $0.reserveCapacity($0.count + numericCast(rhs.count))
  $0.append(contentsOf: rhs)
}
```

It's important to note that `with` does *not* resolve the "FIXME" comment.
Like the `var lhs = lhs` in the original code, `with` only copies value 
types, not reference types. If `RangeReplaceableCollection` included a 
Foundation-like `copy()` method that was guaranteed to return a copy 
even if it was a reference type, `with` would work nicely with that 
solution:

```swift
return with(lhs.copy()) {
  $0.reserveCapacity($0.count + numericCast(rhs.count))
  $0.append(contentsOf: rhs)
}
```

#### Inspecting an Intermediate Value

Suppose you want to inspect a value in the middle of a long method chain.
For instance, you're not sure this is retrieving the type of cell you expect:

```swift
let view = tableView.cellForRow(at: indexPath)?.contentView.withTag(42)
```

Currently, you would need to either split the statement in two so you 
could capture the return value of `cellForRow(at:)` in a constant, or 
insert a very clunky immediate-closure call in the middle of the 
statement. Using `with`, you can stay close to the original expression:

```swift
let view = with(tableView.cellForRow(at: indexPath)) { print($0) }?.contentView.withTag(42)
```

Because the closure doesn't alter `$0`, the cell passes through the 
`with` call unaltered, so it can be used by the rest of the method 
chain.
 
## Detailed Design

We propose adding the following free function to the standard library:

```swift
/// Returns `item` after calling `update` to inspect and possibly 
/// modify it.
/// 
/// If `T` is a value type, `update` uses an independent copy 
/// of `item`. If `T` is a reference type, `update` uses the 
/// same instance passed in, but it can substitute a different 
/// instance by setting its parameter to a new value.
@discardableResult
public func with<T>(_ item: T, update: @noescape (inout T) throws -> Void) rethrows -> T {
  var this = item
  try update(&this)
  return this
}
```

`@discardableResult` permits the use of `with(_:update:)` to create a scoped 
temporary copy of the value with a shorter name.

## Impact on Existing Code

This proposal is purely additive and has no impact on existing code.

## Alternatives Considered

**Doing nothing**: `with` is a mere convenience; any code using it could be 
written another way.
If rejected, users could continue to write code using the longhand form,
the various closure-based techniques, or homegrown versions of `with`.

**Using method syntax**: Some list members preferred a syntax
that looked more like a method call with a trailing closure:

```swift
let questionLabel = UILabel().with {
    $0.textAlignment = .Center
    $0.font = UIFont(name: "DnealianManuscript", size: 72)
    $0.numberOfLines = 0
    addSubview($0)
}
```

This would require a more drastic solution as it's not possible to add
methods to all Swift types. Nor does it match the existing
design of functions like `withExtendedLifetime(_:_:)`, `withUnsafePointer(_:_:)`, 
and `reflect(_:)`.

**Adding `self` rebinding**: Some list members wanted a way to bind
`self` to the passed argument, so that they can use implicit `self` to 
eliminate `$0.`:

```swift
let supView = self
let questionLabel = with(UILabel()) { 
    self in
    textAlignment = .Center
    font = UIFont(name: "DnealianManuscript", size: 72)
    numberOfLines = 0
    supView.addSubview(self)
}
```

We do not believe this is practical to propose in the Swift 3 timeframe, and 
we believe `with` would work well with this feature if it were added later.

**Adding method cascades**: A competing proposal was to introduce a way to 
use several methods or properties on the same instance; Dart and Smalltalk 
have features of this kind.

```swift
let questionLabel = UILabel()
    ..textAlignment = .Center
    ..font = UIFont(name: "DnealianManuscript", size: 72)
    ..numberOfLines = 0
addSubview(questionLabel)
```

Like rebinding `self`, we do not believe method cascades are practical 
for the Swift 3 timeframe. We also believe that many of `with`'s use 
cases would not be subsumed by method cascades even if they were added.
