# Abolish `ImplicitlyUnwrappedOptional` type

* Proposal: [SE-0054](0054-abolish-iuo.md)
* Author: [Chris Willmore](http://github.com/cwillmor)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000084.html)
* Implementation: [apple/swift#2322](https://github.com/apple/swift/pull/2322)

## Introduction

This proposal seeks to remove the `ImplicitlyUnwrappedOptional` type from the
Swift type system and replace it with an IUO attribute on declarations.
Appending `!` to the type of a Swift declaration will give it optional type and
annotate the declaration with an attribute stating that it may be implicitly
unwrapped when used.

Swift-evolution thread: ["Abolish IUO Type"](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012752.html)

## Motivation

The `ImplicitlyUnwrappedOptional` ("IUO") type is a valuable tool for importing
Objective-C APIs where the nullability of a parameter or return type is
unspecified. It also represents a convenient mechanism for working through
definite initialization problems in initializers. However, IUOs are a
transitional technology; they represent an easy way to work around un-annotated
APIs, or the lack of language features that could more elegantly handle certain
patterns of code. As such, we would like to limit their usage moving forward,
and introduce more specific language features to take their place. Except for a
few specific scenarios, optionals are always the safer bet, and we’d like to
encourage people to use them instead of IUOs.

This proposal seeks to limit the adoption of IUOs to places where they are
actually required, and put the Swift language on the path to removing
implicitly unwrapped optionals from the system entirely when other technologies
render them unnecessary. It also completely abolishes any notion of IUOs below
the type-checker level of the compiler, which will substantially simplify the
compiler implementation.

## Proposed solution

In this proposal, we continue to use the syntax `T!` for declaring implicitly
unwrapped optional values in the following locations:

* property and variable declarations
* initializer declarations
* function and method declarations
* subscript declarations
* parameter declarations (with the exception of vararg parameters)

However, the appearance of `!` at the end of a property or variable
declaration's type no longer indicates that the declaration has IUO type;
rather, it indicates that (1) the declaration has optional type, and (2) the
declaration has an attribute indicating that its value may be implicitly
forced. (No human would ever write or observe this attribute, but we will
refer to it as `@_autounwrapped`.) Such a declaration is referred to henceforth
as an IUO declaration.

Likewise, the appearance of `!` at the end of the return type of a function
indicates that the function has optional return type and its return value may
be implicitly unwrapped. The use of `init!` in an initializer declaration
indicates that the initializer is failable and the result of the initializer
may be implicitly unwrapped. In both of these cases, the `@_autounwrapped`
attribute is attached to the declaration.

A reference to an IUO variable or property prefers to bind to an optional, but
may be implicitly forced (i.e. converted to the underlying type) when being
type-checked; this replicates the current behavior of a declaration with IUO
type. Likewise, the result of a function application or initialization where
the callee is a reference to an IUO function declaration prefers to retain its
optional type, but may be implicitly forced if necessary.

If the expression can be explicitly type checked with a strong optional type,
it will be. However, the type checker will fall back to forcing the optional if
necessary. The effect of this behavior is that the result of any expression
that refers to a value declared as `T!` will either have type `T` or type `T?`.
For example, in the following code:

```Swift
let x: Int! = 5
let y = x
let z = x + 0
```

… `x` is declared as an IUO, but because the initializer for `y` type checks
correctly as an optional, `y` will be bound as type `Int?`. However, the
initializer for `z` does not type check with `x` declared as an optional
(there's no overload of `+` that takes an optional), so the compiler forces the
optional and type checks the initializer as `Int`.

This model is more predictable because it prevents IUOs from propagating
implicitly through the codebase, and converts them to strong optionals, the
safer option, by default.

An IUO variable may still be converted to a value with non-optional type,
through either evaluating it in a context which requires the non-optional type,
explicitly converting it to a non-optional type using the `as` operator,
binding it to a variable with explicit optional type, or using the force
operator (`!`).

Because IUOs are an attribute on declarations rather than on types, the
`ImplicitlyUnwrappedOptional` type, as well as the long form
`ImplicitlyUnwrappedOptional<T>` syntax, is removed. Types with nested IUOs are
no longer allowed. This includes types such as `[Int!]` and `(Int!, Int!)`.

Type aliases may not have IUO information associated with them. Thus the
statement `typealias X = Int!` is illegal. This includes type aliases resulting
from imported `typedef` statements. For example, the Objective-C type
declaration

```Objective-C
typedef void (^ViewHandler)(NSView *);
```

... is imported as the Swift type declaration

```Swift
typealias ViewHandler = (NSView?) -> ()
```

Note that the parameter type is `NSView?`, not `NSView!`.

## Examples

```Swift
func f() -> Int! { return 3 } // f: () -> Int?, has IUO attribute
let x1 = f() // succeeds; x1: Int? = 3
let x2: Int? = f() // succeeds; x2: Int? = .some(3)
let x3: Int! = f() // succeeds; x3: Int? = .some(3), has IUO attribute
let x4: Int = f() // succeeds; x4: Int = 3
let a1 = [f()] // succeeds; a: [Int?] = [.some(3)]
let a2: [Int!] = [f()] // illegal, nested IUO type
let a3: [Int] = [f()] // succeeds; a: [Int] = [3]

func g() -> Int! { return nil } // f: () -> Int?, has IUO attribute
let y1 = g() // succeeds; y1: Int? = .none
let y2: Int? = g() // succeeds; y2: Int? = .none
let y3: Int! = g() // succeeds; y3: Int? = .none, has IUO attribute
let y4: Int = g() // traps
let b1 = [g()] // succeeds; b: [Int?] = [.none]
let b2: [Int!] = [g()] // illegal, nested IUO type
let b3: [Int] = [g()] // traps

func p<T>(x: T) { print(x) }
p(f()) // prints "Optional(3)"; p is instantiated with T = Int?

if let x5 = f() {
  // executes, with x5: Int = 3
}
if let y5 = g() {
  // does not execute
}
```

## Impact on existing code

These changes will break existing code; as a result, I would like for them to
be considered for inclusion in Swift 3. This breakage will come in two forms:

* Variable bindings which previously had inferred type `T!` from their binding
  on the right-hand side will now have type `T?`. The compiler will emit an
  error at sites where those bound variables are used in a context that demands
  a non-optional type and suggest that the value be forced with the `!`
  operator.

* Explicitly written nested IUO types (like `[Int!]`) will have to be rewritten
  to use the corresponding optional type (`[Int?]`) or non-optional type
  (`[Int]`) depending on what's more appropriate for the context. However, most
  declarations with non-nested IUO type will continue to work as they did
  before.

* Unsugared use of the `ImplicitlyUnwrappedOptional` type will have to be
  replaced with the postfix `!` notation.

It will still be possible to declare IUO properties, so the following deferred
initialization pattern will still be possible:

```Swift
struct S {
  var x: Int!
  init() {}
  func initLater(x someX: Int) { x = someX }
}
```

I consider the level of breakage resulting from this change acceptable. Types
imported from Objective-C APIs change frequently as those APIs gain nullability
annotations, and that occasionally breaks existing code too; this change will
have similar effect.

## Alternatives considered

* Continue to allow IUO type, but don't propagate it to variables and
  intermediate values without explicit type annotation. This resolves the issue
  of IUO propagation but still allows nested IUO types, and doesn't address the
  complexity of handling IUOs below the Sema level of the compiler.

* Remove IUOs completely. Untenable due to the prevalence of deferred
  initialization and unannotated Objective-C API in today's Swift ecosystem.
