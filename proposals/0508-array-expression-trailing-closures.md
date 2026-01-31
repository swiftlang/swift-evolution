# Array expression trailing closures

* Proposal: [SE-0508](0508-array-expression-trailing-closures.md)
* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Active review (January 30...February 12, 2026)**
* Implementation: [swiftlang/swift#86244](https://github.com/swiftlang/swift/pull/86244)
* Review: ([pitch](https://forums.swift.org/t/support-trailing-closure-syntax-for-single-argument-array-and-dictionary-initializers/83900)) ([review](https://forums.swift.org/t/se-0508-array-expression-trailing-closures/84479))

## Summary of changes

We add support for using trailing closures following array types in expressions.

## Motivation

A project may choose to define an `init` on `Array` that takes a trailing closure. For example, in a project with an `@ArrayBuilder` result builder, an `init` taking a result builder closure would be a logical addition:

```swift
extension Array {
    init(@ArrayBuilder build: () -> [Element]) {
        self = build()
    }
}
```

Another example could be an `init` that generates and appends elements until the closure returns `nil`:

```swift
extension Array {
    init(generate: () -> Element?) {
        self = []
        while let element = generate() {
            append(element)
        }
    }
}
```

In almost all cases, an `init` taking a single closure can be called using trailing closure syntax following the type name. However, in the case of `Array` or `Dictionary` types, this is not currently allowed by the parser.

A trailing closure after an array or dictionary literal is currently excluded from the expression, instead being interpreted as either a part of the surrounding declaration (always resulting in an error) or a separate unused closure (which almost always results in a "closure expression is unused" error):

```swift
// error: 'let' declarations cannot be computed properties
let value = [String] {
  "a"
}

// error: variable with getter/setter cannot have an initial value
var value = [String] {
  "a"
}

// error: closure expression is unused
let value = [String]
{
  "a"
}
```

To use a trailing closure here, you would instead have to write something like:

```swift
let value = [String].init {
  "a"
}

let value = [String]() {
  "a"
}
```

However, this trailing closure syntax _is_ currently supported for `InlineArray`s (for example, using this [existing initializer](https://developer.apple.com/documentation/swift/inlinearray/init(_:))):

```swift
let powersOfTwo = [4 of Int] { index in
  1 << index
}
```

This syntax not being supported for `Array` and `Dictionary` is unnecessarily limiting, and inconsistent with `InlineArray`.

## Proposed solution

We should add support for using trailing closures following array types and dictionary types in expressions by enabling braces after an array or dictionary literal to be parsed as a trailing closure.

These examples would now parse successfully and would be interpreted as calling `init(_:)` with a trailing closure:

```swift
let value = [String] {
  "a"
}

let value = [String: Int] {
  (key: "a", value: 42)
}
```

## Detailed design

There are two things to know about the current parsing behavior:

1. When parsing an expression, `[...]` tokens are always parsed as an array or dictionary _literal_ value. In this case of types like `[String]` or `[String: Int]`, this is later converted to an array / dictionary _type_ during type checking if needed. It's always possible that `[String]` is actually a single-element array literal using a `let String = "a"` property.
2. When encountering an open brace token (`{`) following an expression, this is interpreted as a trailing closure _unless_ the previous expression is a literal.

Before the introduction of `callAsFunction` in Swift 5.2 ([SE-0253](https://github.com/swiftlang/swift-evolution/blob/e3aaa2104de497dec3dcce4ede2085af6e7511b8/proposals/0253-callable.md?plain=1#L29)), this logic was pretty reasonable: other than `callAsFunction`, there would be no valid use case of a trailing closure following a proper _literal_ value.

To enable trailing closures following `Array` and `Dictionary` types in expressions, we will enable support for trailing closures following array and dictionary literals.

Primarily, this enables these `init(_:)` trailing closure examples to parse and compile successfully:

```swift
let value = [String] {
  "a"
}

let value = [String: Int] {
  (key: "a", value: 42)
}
```

As a consequence, this also enables support for trailing closure `callAsFunction` call sites:

```swift
extension Array {
    func callAsFunction<T>(mapElement: (Element) -> T) -> [T] {
        map(mapElement)
    }
}

let value = ["a", "b", "c"] {
    $0.uppercased()
}
```

Outside of a minor source compatibility point (see below), there are no downsides to enabling this syntax. It improves expressiveness and consistency of the language for very little cost.

## Source compatibility

This parsing update would change the meaning of any existing closure literal following an array literal. However, there are very few cases in the language today where this actually results in compiling code.

Most examples result in a `closure expression is unused` error:

```swift
["a", "b", "c"] { // error: closure expression is unused
  "a"
}

["a", "b", "c"]
{ "a" } // error: closure expression is unused
```

The only case that this doesn't currently result in an error would be a result builder that accepts closure values:

```swift
@resultBuilder
enum FunctionArrayBuilder {
    static func buildBlock(_ components: (() -> Void)...) -> [() -> Void] {
        components
    }
}

@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array = ["a", "b", "c"]
    { print(array) }
}
```

This would no longer compile following this change. However, this result builder use case is already very fragile and impractical.

First, sequential closure literals are not supported without semicolons, so a result builder taking closures has limited utility:

```swift
@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    { print("a") }
    { print("b") } // error: extra trailing closure passed in call
}
```

If you do create an example that compiles, small changes like adding an additional variable causes it to no longer compile:

```swift
// Compiles
@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array = ["a", "b", "c"]
    { print(array) };
    { print(array.count) }
}
```

```swift
// Doesn't compile
@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array = ["a", "b", "c"]
    let count = array.count
    { print(array) }; // error: cannot convert value of type '()' to closure result type 'Bool'
    { print(count) }
}
```

If using a value of a `callAsFunction` type, adding an additional variable can actually still compile but with a different meaning at runtime:

```swift
extension Int {
  func callAsFunction(_ closure: () -> Void) -> Int {
    closure()
    return self
  }
}

@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array = ["a", "b", "c"]
    let count = array.count
    { print(array) }; // callAsFunction trailing closure, not an accumulated result builder value
    { print(count) }
}
```

This use case is already very fragile, and there are no known examples of this use case (a standalone closure expression following an array literal within a result builder) happening in practice. Rather than accommodating it with more complicated or inconsistent parsing rules, we will accept this specific source break.

## ABI compatibility

This proposal simply enables new callsite syntax for existing declarations and has no ABI impacts.

## Implications on adoption

This proposal simply enables new callsite syntax for existing declarations and has no adoption implications.

## Future directions

### Enable trailing closures for all literals

This proposal ony enables trailing closures following array and dictionary literals. We could go further and enable trailing closures following all literals. This would enable `callAsFunction` trailing closure use cases that are not currently supported:

```swift
extension String {
  func callAsFunction(_ closure: (String) -> Void) {
    closure(self)
  }
}

"Hello world" { // currently, error: closure expression is unused 
  print($0)
}
```

This would be more consistent with other trailing closure use cases, and there are no particular downsides beyond the source compatibility discussion above. However, this also isn't as strongly motivated as the array and dictionary literals, which enables reasonable `init(_:)` use cases. Arrays and dictionaries types are unique because an array / dictionary type expression is initially parsed as a literal due to the potential ambiguity.

## Alternatives considered

### Additional parsing heuristics

#### Require the trailing closure to start on the same line as the array literal

The one potential source break is related to result builder closure expressions on the line following an array literal:

```swift
@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array = ["a", "b", "c"]
    { print(array) }
}
```

This doesn't compile today if the closure starts on the same line as the array literal:

```swift
@FunctionArrayBuilder
var buildFunctions: [() -> Void] {
    let array1 = ["a", "b", "c"] { // error: cannot convert return expression of type '()' to return type '[String]'
        print(array)
    }

    let array2 = ["a", "b", "c"] { // error: variable with getter/setter cannot have an initial value
        ["d"]
    }
}
```

We could avoid the source break by only treating the brace as a trailing closure if on the same line as the array literal closing bracket. However, this would be inconsistent with all other brace / trailing closure use cases, where this Allman brace style is allowed:

```swift
let array = ["a", "b", "c"].map 
{ 
  $0.uppercased()
}

if array.count >= 3
{
  print("success: \(array)")
}
```

Ideally we would avoid an inconsistency like this. Arbitrary inconsistencies add complexity elsewhere in the ecosystem, like code formatting tools.

#### Only support trailing closures following array types, not other array literals

Another hypothetical way to avoid the source break would be to only allow trailing closures follow array / dictionary _types_, not all literals in general. A bare `[String]` type is never a valid expression, so there would be no source compatibility concerns in theory.

However, it's impossible to know at parsing time whether `[String]` represents a type or literal:

```swift
let String = "a"
let array = [String] // an array literal, ["a"]
{ print(array) }
```

We could _narrow_ the source break by only allowing trailing closures following _single-element_ array or dictionary literals that contain a single identifier (e.g. would parse successfully as a type), but this would unnecessarily eliminate the `callAsFunction` use case. 

## Acknowledgements

Thank you to Tony Allevato for encouraging to investigate this improvement and sharing feedback on the pitch.

Thank you to for Xiaodi Wu for sharing feedback on the pitch and developing the argument that the closure result builder use case is too fragile to be worth accommodating.

Thank you to Jed Fox for sharing the `InlineArray` trailing closure example.
