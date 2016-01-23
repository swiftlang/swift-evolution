# Introducing interfaces

* Proposal: [SE-NNNN](https://github.com/Anton3/swift-evolution/edit/master/proposals/0000-introducing-interfaces.md)
* Author(s): [Anton3](https://github.com/Anton3)
* Status: **Review**
* Review manager: TBD

## Introduction

Separate the concepts of statically dispatched protocols used as type constraints and dynamically dispatched interfaces used as abstract base classes.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/005157.html)

## Motivation

### Usage in static vs dynamic dispatch

Let us imagine two protocols: `Comparable` (like one in standard library) and `Drawable`.

```swift
protocol Comparable {
  func ==(lhs: Self, rhs: Self) -> Bool
  func <(lhs: Self, rhs: Self) -> Bool
}

protocol Drawable {
  func draw(canvas: Canvas)
}
```

They are both protocols, but they have drastically different use cases:

```swift
func sort<T: Comparable>(inout array: [T]) {
  //...
  if array[i] < array[j] {
    swap(array[i], array[j])
  }
  //...
}

func drawAll(objects: [Drawable], on canvas: Canvas) {
  for object in objects {
    object.draw()
  }
}
```

`Comparable` is used only as a type constraint, in static contexts. The inclusion of associated types (or `Self`, as in this case) prevents it from being used in dynamic dispatch:

```swift
func compareTwo(first: Comparable, _ second: Comparable) -> Int {  // error!
  if first < second {
    return -1
  }
  //...
}
```

The code above yields an error, and rightfully so, because if the real types of first and second are not equal, they cannot actually be compared.

On the other side, `Drawable` can also be used in static contexts if we know the actual specific types at compile time:

```swift
func canvasWithObject<T: Drawable>(object: T) -> Canvas {
  var canvas = Canvas()
  object.draw(canvas)
  return canvas
}
```

Unfortunately, this underlying seperation of "static" and "dynamic" protocols cannot be expressed in current type system. We become aware of it only at the time we make an error:

```
protocol 'Comparable' can only be used as a generic constraint because it has Self or associated type requirements
```

### Extension methods

Another difference between the kinds of protocols lies in extension methods.

Two types of protocol extension methods exist. Example:

```swift
protocol Drawable {
  func draw(canvas: Canvas)
  func drawEverywhere(canvases: [Canvas])
  var dimensions: Rectangle { get }
}

extension Drawable {
  // 1. "static extension method"
  // draw dimensions rectangle in Red color
  func drawPlaceholder(canvas: Canvas) { /*...*/ }
  
  // 2. "dynamic extension method"
  // apply draw to each of canvases
  func drawEverywhere(canvases: [Canvas]) { /*...*/ }
}

struct Circle : Drawable {
  // implement draw() and dimensions
  
  // 1. "static extension method"
  // draw dimensions rectangle in Blue color
  func drawPlaceholder(canvas: Canvas) { /*...*/ }
  
  // 2. "dynamic extension method"
  // apply draw to each of canvases, with increased performance
  func drawEverywhere(canvases: [Canvas]) { /*...*/ }
}
```

The difference shows up in dynamic dispatch:

```swift
var object: Drawable = Circle()
object.drawPlaceholder(canvas)  // calls method from Drawable, paints in Red
object.drawEverywhere(canvases) // calls method from Circle
```

The first call is currently allowed, and it may cause confusion. Indeed, extension method is overridden, but default implementation is called instead. Such behaviour is not used anywhere else in the language.

### Protocol inheritance

The distinction between a protocol which `has Self or associated type requirements` and "other protocols" is not easily seen. One has to look through the whole body of the protocol in search of usage of associated types or usage of `Self`. Moreover, the restrictions may come from parent protocols:

```swift
// a.swift
protocol CanvasType { /*...*/ }

protocol UniversalDrawable {
  typealias Canvas: CanvasType
  func draw(canvas: Canvas)
}

// b.swift
protocol DrawableWithSize : UniversalDrawable {
  var size: Double { get }
}

// c.swift
func sumSize(objects: [DrawableWithSize]) -> Double {
  return objects.map { obj in obj.size }.reduce(0.0, +)
}
```

The user gets an error from `c.swift`. To get where the error actually comes from, he is required to perform the following actions:

1. Learn what associated types are in "The Swift Programming Language" book
2. Go to `b.swift` and search for "clues"; not find anythong
3. Go to `a.swift` and looking through the body of a parent of `DrawableWithSize`, finally find a typealias

Isn't that ridiculous?

## Proposed solution

### Intentions

1. Suggest clear terms for protocols with `Self or associated type requirements` and without them
2. Allow this distinction to be expressed in the language
3. Make corresponding restrictions on usage of protocols clear from their declarations
4. Prevent errors of using statically dispatched extension methods in "dynamic" protocols

### Introduction of `interface`

I suggest leaving the term "protocol" for current statically dispatched protocols and introduce `interface` keyword for current protocols that may be used in dynamic dispatch. The first example now looks like:

```swift
protocol Comparable {
  func ==(lhs: Self, rhs: Self) -> Bool
  func <(lhs: Self, rhs: Self) -> Bool
}

interface Drawable {
  func draw(canvas: Canvas)
}
```

Trying to use `Self` or associated types in an interface will result in a compilation error (also see a note below):

```swift
interface Drawable {
  mutable func join(other: Self)  // error: "cannot use Self in interface"
  typealias Canvas: CanvasType    // error: "cannot use associated types in interface"
}
```

On the other hand, declaring a would-be interface as a protocol is not an error. Actually, a rule of thumb is to use interfaces only if we absolutely need dynamic dispatch:

```swift
protocol Drawable {
  func draw(canvas: Canvas)
}
```

Trying to use protocols in dynamic dispatch must result in a (clear) compilation error:

```swift
func compareTwo(first: Comparable, _ second: Comparable) -> Int {  // error: "protocols can only be used as type constraints"
  if first < second {
    return -1
  }
  //...
}
```

On the other hand, interfaces can be used with static dispatch either as type constraints or if compiler knows exact type of a variable.

### Extensions

All extension methods in protocols must be statically dispatched (with exception of class inheritance), as they currently do.

All extension methods in interfaces must either be dynamically dispatched (or statically if possible at usage), or be explicitly declared as final. Back to our extension example:

```swift
interface Drawable {
  func draw(canvas: Canvas)
  func drawEverywhere(canvases: [Canvas])
  var dimensions: Rectangle { get }
}

extension Drawable {
  final func drawPlaceholder(canvas: Canvas) { /*...*/ }
  func drawEverywhere(canvases: [Canvas]) { /*...*/ }
}

struct Circle : Drawable {
  // implement draw() and dimensions
  func drawEverywhere(canvases: [Canvas]) { /*...*/ }
}

var object: Drawable = Circle()
object.drawPlaceholder(canvas)  // ok, we agree to call the final method from Drawable
object.drawEverywhere(canvases) // ok, dynamically dispatched
```

## Detailed design

### Clarification on `Self`

There is one place where `Self` can be used with current protocols in dynamic context: as a return type. Interfaces should continue to allow for that:

```swift
interface IntAddable {
  func add(other: Int) -> Self
}
```

### Inheritance

As protocols can have associated types and interfaces cannot, an interface cannot inherit from a protocol:

```swift
interface Drawable : Comparable { /*...*/ }  // error!
```

On the other hand, a protocol can inherit from an interface. It then loses the ability to act in dynamic contexts, but can use `Self` or associated types.

```swift
protocol DrawableEquatable : Drawable, Equatable {
  func ==(left: Self, right: Self) {
    return canvasWithSingle(left) == canvasWithSingle(right)
  }
}

struct Circle : DrawableEquatable { /*...*/ }

let circle            = Circle()
let drawableEquatable = circle as DrawableEquatable  // error!
let drawable          = circle as Drawable           // ok
```

### Standard Library

There are currently over 50 protocols in Swift Standard Library. Many of them have associated types, and the proposal will not affect them. Which of the rest should become interfaces, requires a more deep insight.

As already said, a current protocol should become an interface iff it is intended to be used in dynamic context.

A rule of thumb is that if it is useful to have a heterogenous collection of instances of this protocol and polymorphically interact with them, then it probably should become an interface.

- `BooleanType` should remain a protocol. Passing a `BooleanType` to a function is pointless: we can just pass a `Bool`
- Likewise, all Convertibles should be declared as protocols
- `AnyObject`, `CVarArgType`, `ErrorType` are commonly used in dynamic dispatch and should become interfaces

## Impact on existing code

Applications that declare protocols without `Self` or associated types and use them in dynamic contexts, must change `protocol` to `interface` in declarations of such protocols. This transition can be performed automatically.

Swift programmers that use current Standard Library protocols, that will remain protocols, in dynamic dispatch, must rewrite their code to avoid such usage of protocols, or if it is inevitable in that specific context, create their own interfaces containing needed methods. Such transition cannot be performed automatically, but the compiler error will contain enough information to perform it manually. Note that such use cases are considered to be rare enough to redeclare all current Standard Library protocols as interfaces.

Applications that use unsafe statically dispatched extension methods in interfaces, will need to either declare them final (if they are currently not overridden anywhere), or make them dynamically dispatched by adding them to the body (if overridden). This transition can be performed automatically.

## Alternatives considered

### Keywords discussion

There is not a consensus on what keywords should be used for statically and dynamically dispatched protocols. The suggestions are:

static | dynamic
--- | ---
protocol | interface
protocol | dynamic protocol
protocol | existential protocol
trait | protocol

### Existential types proposal

The proposal for existential types states that all protocols, including ones that have `Self` or associated types, can act in dynamic dispatch. However, current proposal aims to differentiate between protocols that can be used in dynamic dispatch and protocols that cannot.

On the other hand, variables of existential types, which have `Self` or associated types, need unpacking before actual use. This still will not work:

```swift
func compareTwo(first: Comparable, _ second: Comparable) -> Int {  // ok
  if first < second {                                              // error!
    return -1
  }
  //...
}
```

Theoretically, the two proposals can be composed. Interfaces would be "naturally dynamic" and protocols would need unpacking. Although, this solution does not seem to be the best case for both proposals.
