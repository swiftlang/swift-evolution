# `is case` expressions

* Proposal: [SE-0XXX](0XXX-is-case-expressions.md)
* Authors: [Cal Stephens](https://github.com/calda), [Matthew Cheok](https://github.com/matthewcheok), [Jordan Rose](https://belkadan.com/blog)
* Review Manager: TBD
* Status: **Implementation available**
* Implementation: [apple/swift#64901](https://github.com/apple/swift/pull/64901)
* Review: ([draft proposal](https://github.com/matthewcheok/swift-evolution/blob/is-case-expr/proposals/0xxx-is-case-expressions.md))

## Introduction

It's often useful to check whether or not an enum matches a specific case. This is trivial for simple enums without associated values, but is not well-supported today for enum cases with associated values.

We should introduce a new `is case` expression that lets you evaluate the result of any pattern matching an expression in a way similar to a `switch` or `if case` statement:

```swift
enum Destination {
  case inbox
  case messageThread(id: Int)
}

let destination = Destination.thread(id: 42)
print(destination is case .inbox) // false
print(destination is case .thread) // true
print(destination is case .thread(id: 0)) // false
print(destination is case .thread(id: 42)) // true

// SwiftUI view
VStack {
  HeaderView(inThread: destination is case .thread)
  ...
}
```

## Motivation

It's often useful to check whether or not an enum matches a specific case. This is trivial for simple enums without associated values, which automatically conform to `Equatable`:

```swift
enum Destination {
  case inbox
  case messageThread
}

let destination = Destination.messageThread
print(destination == .messageThread)
```

After adding an associated value, you can no longer use value equality for this:

```swift
enum Destination: Equatable {
  case inbox
  case messageThread(id: Int)
}

let destination = Destination.messageThread(id: 42)
// error: member 'messageThread(id:)' expects argument of type 'Int'
print(destination == .messageThread)
```

For enums with associated values, the only way to implement this check is by using an if / switch statement. One may assume that Swift 5.9's support for if / switch expressions would be a suitable way to implement this check, but those expressions cannot be written in-line:

```swift
// error: 'if' may only be used as expression in return, throw, or as the source of an assignment
// Even if this was allowed, it would be pretty verbose.
HeaderView(inThread: if case .messageThread = destination { true } else { false })
```

Instead, the result of this check must be either assigned to a variable or defined in a helper:

```swift
let isMessageThread = if case .messageThread = destination { true } else { false }
// or:
let isMessageThread = switch destination {
  case .messageThread: true
  default: false
}

HeaderView(inThread: isMessageThread)
```

Checking whether or not a value matches a pattern is already "truthy", so the extra ceremony mapping the result of this condition to a boolean is semantically redundant. This syntax is also quite verbose, and can't be written inline at the point of use.

This problem is such a pain-point that some have even recommended mirroring with a [parallel](https://forums.swift.org/t/request-ability-to-refer-to-an-enum-case-in-abstract-without-its-associated-value/410) [enum](https://forums.swift.org/t/comparing-enums-without-their-associated-values/18944/3) that has [no associated values](https://forums.swift.org/t/swift-enum-property-without-initializing-the-enum-case-with-an-associated-value/17539) in order to benefit from direct equality-checking:

```swift
enum Destination {
  case inbox
  case messageThread(id: Int)

  enum Case {
    case inbox
    case messageThread
  }

  var `case`: Case {
    switch self {
      case .inbox: .inbox
      case .messageThread: .messageThread
    }
  }
}

HeaderView(inThread: destination.case == .messageThread)
```

Another common pattern is to manually implement boolean properties for each enum case:

```swift
enum Destination {
  case inbox
  case messageThread(id: Int)

  var isInbox: Bool {
    switch self {
    case .inbox:
      true
    case .messageThread:
      false
    }
  }

  var isMessageThread: Bool {
    switch self {
    case .inbox:
      false
    case .messageThread:
      true
    }
  }
}

HeaderView(inThread: destination.isMessageThread)
```

These ad-hoc solutions are non-trivial to maintain and place the burden of keeping them up-to-date on the author.

Instead, we propose adding new type of expression, `<expr> is case <pattern>`, that evaluates to true or false based on whether `<expr>` matches `<pattern>`. That would allow us to write this sort of check inline and succinctly:

```swift
HeaderView(inThread: destination is case .messageThread)
```

## Detailed Design

The following expression type would be added to the language grammar:

```swift
infix-expression -> is case <pattern>
```

`<expr> is case <pattern>` should be considered equivalent to the following code:

```swift
({ () -> Bool in
  switch <expr> {
  case <pattern>: true
  default: false
  }
})()
```

Unlike if / switch expressions added in Swift 5.9, `if case` expressions would be usable anywhere you can write an expression.

The expression would support matching any type of pattern that can be used in a `switch` statement:

```swift
foo is case .bar // enum case
foo is case .bar(42) // enum case with associated values
foo is case .bar(42, _) // enum case with partially matched associated values
foo is case 42 // integer literal
foo is case true // boolean literal
foo is case "A string" // string literal
foo is case bar // other expression
```

But since these expression are not part of a control flow structure, they won't support binding associated values to variables. For example, the following usage would not be allowed:

```swift
// Not allowed, since there isn't a new scope where the bound property would be available
foo is case .bar(let value)
MessagesView(inThread: screen is case .messageThread(let userId))
```

This syntax can also be extended by overloading the `~=` operator just as in within `switch` and `if case` statements.

At face value this seems like it would create the opportunity for some "silly" conditions like `foo is case 42`. Despite being a bit silly, these conditions are harmless and are important to support for two reasons:
 1. maintaining feature parity with `case <pattern>` in switch statements is important to ensure a consistent mental model of how pattern matching works in Swift
 2. very similar spellings are already possible today in conditions like `if case 42 = foo { true } else { false }`

## Precedence

By analogy with `<expr> is <type>`, this expression should be usable within `&&`/`||` chains. That is, `x && y is case .z && w` should be equivalent to `x && (y is case .z) && w`. At the same time, other binary operators need to bind more tightly: `x is case y ..< z` should be interpreted as `x is case (y ..< z)`. This behavior is already implemented for chains of infix-expressions using precedence, but adding expression-patterns to the mix may be tricky to implement.

Open question: should `x ?? y is case .z` be treated as `x ?? (y is case .z)` or `(x ?? y) is case .z`? The former matches `is`'s CastingPrecedence, designed around `as?`, but the latter is still an option, and both have plausible uses: `alwaysDark ?? (systemMode is case .dark)` vs `(overriddenMode ?? systemMode) is case .dark`. The precedence of `is case` should be higher than `ComparisonPrecedence` no matter what, though.

## Source compatibility and ABI

This is an additive change to expression syntax that requires no additional runtime support; it has no source- or binary-compatibility implications beyond not being available in earlier versions of the compiler.

## Alternatives considered

### Do nothing

As of Swift 5.9 ([SE-390](https://github.com/apple/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md)), you can implement this with `if case <pattern> = <expr> { true } else { false }`. These conditions are verbose and cannot be written in-line in other expressions, so are not a sufficient replacement for `is case` expressions. 

Similar variants of these types of syntax can also coexist. For example, Rust provides a `matches!` macro in its standard library even though it also supports control flow expressions:

```rs
#[derive(Copy, Clone)]
enum Destination {
    Inbox,
    MessageThread { id: i64 },
}

fn main() {
    let destination = Destination::MessageThread { id: 42 };

    // Analogous to proposed `screen is case .messageThread` syntax
    println!("{}", matches!(destination, MessageThread)); // prints "true"

    // Analogous to if / switch expression syntax, but can be used in-line
    println!("{}", if let MessageThread = destination { true } else { false }); // prints "true"
}
```

### Allow variable bindings

If we lifted the restriction on variable bindings, it would be possible to check against an enum case and bind its associated value to a local scope in single expression, such as:

```swift
if destination is case .messageThread(let id) {
  // Do something with `id` here
}
```

This would effectively be an alternative spelling of the existing `if case` syntax:

```swift
if case .messageThread(let id) = destination {
  // Do something with `id` here
}
```

Using `is case` syntax in this way is potentially an improvement over `if case` syntax, since `if case` syntax is well-known for having poor autocomplete support. Despite this, there are several downsides to an approach like this.

Most importantly, `is case` expressions could only support bindings in a very narrow context:

```swift
// We can't support bindings in general, since there isn't a scope to bind the new variables in:
HeaderView(inThread: destination is case .messageThread(let userId))

// In theory we could support bindings in if conditions:
if destination is case .messageThread(let id) {
  // Do something with `id` here
}

// But this doesn't work when combining `is case` expressions with other boolean operators:
if !(destination is case .messageThread(let id)) {
  // `destination` is definitely not `.messageThread`, so we can't bind `id`
}

if destination is case .messageThread(let id) || destination is case .inbox {
  // `destination` may not be `.messageThread`, so we can't bind `id`
}
```

It would be confusing and inconsistent for `is case` expressions to support different functionality depending on the context. It would also be less-than-ideal to have two separate spellings of the exact same feature. Since this functionality is already supported by `if case` syntax, we don't need to support it here.

### Case-specific computed properties

Another approach could be to synthesize computed properties for each enum case, either using compiler code synthesis or a macro.

For example, for  `case foo(bar: Int, baz: Int)` we could synthesize some or all of the following computed instance properties:
- `isFoo: Bool`
- `asFoo: (bar: Int, baz: Int)?`
- `bar: Int?`
- `bar: Int (if every case has a field bar: Int)`

This would handle the most common use for `is case`, checking if a value with known enum type has a particular case. However, it does not cover all the use cases, such as matching nested / partial values.

There are also some key drawbacks to an approach like this:
 1. Automatically synthesizing these properties for every enum case would result in a large code size increase, so we likely wouldn't want to enable this by default.
 2. If this is not enabled by default, then this would only be useful in cases where the owner of the enum declaration opted-in to this functionality. Since this doesn't impose any additional semantic requirements on the author of the enum declaration (e.g. like with `CaseIterable`), there aren't any semantic benefits to making this opt-in.

### Alternative spellings

Some potential alternative spellings for this feature include:

```swift
// case <pattern> = <expr>
// Consistent with the existing `if case`, but not evocative of a boolean condition.
HeaderView(inThread: case .messageThread = destination)

// <expr> case <pattern>
// Not evocative of a boolean condition
HeaderView(inThread: destination case .messageThread)

// <expr> is <pattern>
// Less clearly related to pattern matching (always indicated by `case` elsewhere in the language)
HeaderView(inThread: destination is .messageThread)

// <expr> == <pattern>
// Special case support for a specific operator. 
// Could be confusing to overload == with multiple different types of conditions.
// Ambiguous for enum cases without assoicated values (which equality codepath would it use?).
HeaderView(inThread: destination == .messageThread(_))
```

Of these spellings, `<expr> is case <pattern>` is the best because:
 1. it's clearly a condition that evaluates to a boolean
 2. it includes the keyword `case` to indicate its relationship with existing pattern matching syntax (switch cases, `if case`)
 3. it doesn't introduce conflicts or ambiguity with existing language features

## Acknowledgments

Andrew Bennett was the first person who suggested the spelling is case for this operation, way back in [2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2).

Alex Lew ([2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2)), Sam Dods ([2016](https://forums.swift.org/t/proposal-treat-case-foo-bar-as-a-boolean-expression/2546)), Tamas Lustyik ([2017](https://forums.swift.org/t/testing-enum-cases-with-associated-values/7091)), Suyash Srijan ([2018](https://forums.swift.org/t/comparing-enums-without-their-associated-values/18944)), Owen Voorhees ([2019](https://forums.swift.org/t/pitch-case-expressions-for-pattern-matching/20348)), Ilias Karim ([2020](https://forums.swift.org/t/proposal-sanity-check-assigning-a-case-statement-to-a-boolean/40584)), and Michael Long ([2021](https://forums.swift.org/t/enumeration-case-evaluates-as-boolean/54266)) have brought up this "missing feature" in the past, often generating good discussion. (There may have been more that we missed as well, and this isn't even counting "Using Swift" threads!)

Jon Hull ([2018](https://forums.swift.org/t/if-case-in/15000)), among others, for related discussion on restructuring if case.
