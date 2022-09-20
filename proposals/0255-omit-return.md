# Implicit returns from single-expression functions

* Proposal: [SE-0255](0255-omit-return.md)
* Author: [Nate Chandler](https://github.com/nate-chandler)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.1)**
* Implementation: [apple/swift#23251](https://github.com/apple/swift/pull/23251)
* Decision Notes: [Rationale](https://forums.swift.org/t/se-0255-implicit-returns-from-single-expression-functions/22544/113)
* Previous Proposal: [SE-NNNN](https://github.com/DevAndArtist/swift-evolution/blob/single_expression_optional_return/proposals/nnnn-single-expression-optional-return.md)

## Introduction

Swift provides a pleasant shorthand for short closures: if a closure contains just a single expression, that expression is implicitly returned--the `return` keyword can be omitted.  We should provide this shorthand for functions as well.

Swift-evolution thread: [Pitch: Implicit Returns from Single-Expression Functions](https://forums.swift.org/t/pitch-implicit-returns-from-single-expression-functions/21898)

## Motivation

Consider the following implementation of the popular `Collection.sum()` extension:

```swift
extension Sequence where Element == Int {

    func sum() -> Element {
        return reduce(0, +)
    }

}
```

The implementation is extremely brief, weighing in at 19 characters.  Of those 19, however, 7 are consumed by the `return` keyword.  

## Proposed solution

Here's how that same property would look if the single-expression in the body is implicitly returned:

```swift
func sum() -> Element {
    reduce(0, +)
}
```

The expression which is being returned is front and center, not tucked away behind the `return` keyword.

For readers previously exposed to single-expression closure syntax, this will feel completely familiar.  

Even to readers without such exposure, though, the meaning will be clear: When reading the implementation--after the `var` keyword and name--you first encounter the return type and then the single expression within the body.  Since you've just read the return type, can see that there's only one expression in the body, and are told by the compiler that the code is legal, you are forced to conclude that the expression must indeed be returned.

In fact, exposure to functions--whose types are always stated--without an explicit `return` keyword will help prepare new Swift users to understand code like

```swift
let names = persons.map { $0.name }
```

Their prior exposure to functions which implicitly return the single expression in their bodies will lead them to conclude that the closure being passed to map is returning the expression `$0.name` and that the return type of the closure is `String` (the type of `name`, here).

## Detailed design

Interpret the bodies of function-like entities which consist of a single expression as returning that expression--unless the entity's return type is `Void` or the single expression's type is uninhabited.

#### Function-like entities

The following are the function-like entities eligible to implicitly return the single expression in their bodies:

- Functions.  For example:
```swift
func add(lhs: Int, rhs: Int) -> Int { lhs + rhs }
```

- Property accessors.  

With an implicit getter:

```swift
var location: Location { .init(latitude: lat, longitude: long) }
```

With an explicit getter and setter:

```swift
var location: Location {
    get {
        .init(latitude: lat, longitude: long)
    }
    set {
        self.lat = newValue.latitude
        self.long = newValue.longitude
    }
}
```

Since only the `get` accessor may return a value, implicit returns from single-expression accessors will only affect them.

- Subscript accessors.

With an implicit getter:

```swift
struct Echo<T> {
    subscript(_ value: T) -> T { value }
}
```

With an explicit getter and setter:

```swift
struct GuaranteedDictionary<Key: Hashable, Value> {
    var storage: [Key: Value]
    var fallback: Value
    subscript(key: Key) -> Value {
        get {
            storage[key] ?? fallback
        }
        set {
            storage[key] = newValue
        }
    }
}
```

As with property accessors, since only the `get` accessor may return a value, implicit returns only affect them.

- Initializers.

```swift
class Derived: Base {
    required init?() { nil }
}
```

The only legal return from an initializer is `nil`, and that only in the context of a failable initializer.  As a result, that is the only place where an implicit return from an initializer can occur.

#### Exceptions

When a function-like entity's body consists of a single expression, there are two cases where no implicit return will be inserted:

- `Void` return.  In the following code

```swift
func foo() {
    logAndReturn("foo was called")
}

@discardableResult
func logAndReturn(_ string: String) -> String { ... }
```

adding an implicit return to `foo` would result in a type error, namely, `unexpected non-void return in a void function`.  It is reasonable to be able to call a function (here, `logAndReturn`) which returns a value as the only operation performed by another function (here `foo`) which does not return a value.  Moreover, `foo` as written is legal code, so we want to avoid treating this as a type error since doing so would result in source breakage.

- Uninhabited expressions.  In the following code

```swift
func vendAnInteger() -> Int {
    fatalError()
}
```

adding an implicit return would result in the analogous type error (`cannot convert return expression of type 'Never' to return type 'Int'`).  Functions which return values but whose implementations consist solely of a single call to a `Never` returning function are an established practice in Swift--they allow users to put off defining their functions until they are ready to (or forever).  With implicit returns, this function's implementation will have the same meaning as it has today:  The code will compile.  No implicit return will be inserted.  And at runtime the call to `fatalError()` will never return.  Source compatibility will be preserved.

There is one exception, as described in the section below:

## Source compatibility

For the most part, the change is additive, making legal code that is currently illegal.  It does, however, break source compatibility in one case.

In current Swift, when the following code is compiled

```
func bad(value: Int = 0) -> Int { return 0 }
func bad() -> Never { return fatalError() }

func callBad() -> Int { bad() }
```

the call to `bad()` in `callBad()` resolves to the second overload of that name (whose signature is `() -> Never`).  With implicit return, the call will instead resolve to the first overload.

The large downside of breaking source-compatibility is mitigated by the fact that overload sets of which only one member returns `Never` are very rare:  Extensive source compatibility tests have been run against this change without issue.

## Effect on ABI stability

None.  Implementation is only in the parser and type checker.

## Effect on API resilience

None.

## Alternatives considered

- **Maintain source compatibility.**  

Maintaining source compatibility entails teaching the overload resolution system a special case for single-expression functions.  It is possible to do this but would require complicating the type checker.  Far worse it would complicate the language model: 

If source compatibility were maintained, the following two functions

```
func callBad_1() -> Int { bad() }


func callBad_2() -> Int { return bad() }
```

would have different behaviors: `callBad_1` would trap and `callBad_2` would return an `Int`.  

In a Swift with implicit return for single-expression functions, the mental model for users should be that a `return` can be omitted in certain cases and that it doesn't matter whether one is included or not.  Preserving source-compatibility in this case would break that mental model.

&nbsp;

- **Permit implicit return for a subset of declarations.**

This document proposes allowing `return` to be omitted from the following declarations:
- functions
- properties
- subscripts
- initializers

An alternative would be to allow that omission in only a subset of these.  

Concretely, several reasons were given for allowing it in only get-only computed properties:

(1) Unlike functions, get-only properties already have one shorthand, the omission of `get`.  By analogy to the situation with closures, that indicates that they are eligible for the further shorthand of omitting `return`.

Response: This argument applies equally to subscripts which support the same shorthand as properties.  If the reason to permit the `return` to be omitted from properties is that `get` can already be omitted, then that reason leads also to permitting `return` to be omitted from get-only subscripts.  

The differences between get-only subscripts and functions are already few and may be getting fewer ( https://forums.swift.org/t/pitch-static-and-class-subscripts/21850 , https://forums.swift.org/t/draft-throwing-properties-and-subscripts/1786 ).  It would amount to a language inconsistency to allow get-only subscripts but not functions to omit `return`.

(2) Unlike functions, get-only properties always have a return type.

Response: In standard usage, it is much more common to encounter functions which return `Void` than properties.  However, while that usage is far more common, the following is still part of the language:

```swift
var doWork: Void {
    work()
}
```

&nbsp;

- **Making uninhabited types be bottom types.**  

As currently implemented, an implicit conversion from an uninhabited type to any arbitrary type is permitted only if the uninhabited type is the type of the expression in a single-argument function and the arbitrary type is the result type of that function.  If every uninhabited type were a subtype of every type, this implicit conversion could be applied across the board without special casing for the single-argument return scenario.  

While such a feature can be implemented (see the [uninhabited-upcast](https://github.com/nate-chandler/swift/tree/nate/uninhabited-upcast) branch), it doesn't maintain source compatibility or otherwise relate to this feature except in terms of the compiler's implementation.

&nbsp;

- **Use braceless syntax for single-expression functions.**

Some other languages such as Scala and Kotlin allow single-expression functions to be declared without braces.  In Kotlin, this looks like

```kotlin
fun squareOf(x: Int): Int = x * x
```

and in Scala, it looks almost identical (the only difference being the use of `def` instead of `fun`).

```scala
def squareOf(x: Int): Int = x * x
```

Those languages' syntax suggests a similar approach be taken in Swift:

```swift
func square(of x: Int) -> Int = x * x
```

For functions, this might be fine.  For Swift to be self-consistent, a somewhat similar would be needed for properties and subscripts.

```swift
var value: Int {
    get = _storedValue
    set { _storedValue = newValue }
}
```

Unfortunately, this begins moving into ambiguous territory:

```swift
var get: ()
var value: Void {
    get = ()
}
```

In this example, it's unclear whether the braces of `value` either (1) enclose an explicit getter for `value` whose implementation is a single-expression function returning `()` or alternatively (2) enclose the body of an implicit getter whose implementation sets the `get` property to `()`.

&nbsp;

- **Allow implicit return of the last expression even from bodies which consist of more than a single expression.**  

Rust, for example, permits this.  Given functions `foo`, `bar`, and `baz`, all which return integers, the following is a legal function in Rust:

```rust
fn call() -> i64 {
    foo();
    bar();
    baz()
}
```

While this could be permitted in Swift, doing so would lead to asymmetry in code resulting from the fact that Swift is not expression-oriented as Rust is.  Consider a function with some basic branching:

```swift
func evenOrOdd(_ int: Int) -> EvenOrOdd {
    if int % 2 == 0 {
        return .even
    }
    .odd
}
```

Here `.even` is returned for even `Int`s and `.odd` for odd.  Notice that only one of the two returns from the function uses the return keyword!  The same unpleasant function could be written in Rust:

```rust
fn even_or_odd(i: i64) -> EvenOrOdd {
    if i % 2 == 0 { 
        return EvenOrOdd::Even 
    }
    EvenOrOdd::Odd
}
```

In Rust, though, the asymmetry could be resolved by implicitly returning the entire `if` expression:

```rust
fn even_or_odd(i: i64) -> EvenOrOdd {
    if i % 2 == 0 {
        EvenOrOdd::Even
    } else {
        EvenOrOdd::Odd
    }
}
```

That option is not open to us in Swift because conditionals are statements, not expressions in Swift.  Changing Swift into an expression-oriented language would be a radical transformation to the language and is beyond the scope of this change.

&nbsp;

- **Allow the return type to be omitted from the function declarations.**  

Scala, for example, permits this.  In the following code

```scala
def squareOf(x: Int) = x * x
```

the compiler infers that the type of `squareOf` is `(Int) -> Int`.

Haskell takes this further, permitting functions to be written without either explicit inputs or outputs:

```haskell
{-# LANGUAGE PartialTypeSignatures #-}
fac :: _
fac 0 = 1
fac n = n * fac (n - 1)
```

While these features are arguably nice, they greatly increase the complexity of type inference, and are out of scope for this change.

## Acknowledgments

A special thanks to Adrian Zubarev for his prior exploration of the design space culminating in his [proposal](https://github.com/DevAndArtist/swift-evolution/blob/single_expression_optional_return/proposals/nnnn-single-expression-optional-return.md). 

