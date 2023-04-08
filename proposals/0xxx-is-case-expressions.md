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
  case profile(id: Int, edit: Bool)
}

let destination = Destination.messageThread(id: 42)
print(destination is case .inbox) // false
print(destination is case .messageThread) // false
print(destination is case .profile) // false

let destination = Destination.profile(id: 42, edit: true)
print(destination is case .profile) // true
print(destination is case .profile(id: _, edit: true)) // true
print(destination is case .profile(id: 35, edit: true)) // false

// SwiftUI view
VStack {
  HeaderView(inThread: destination is case .messageThread)
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

For this new operator, we much choose which precedence group it belongs to. The two most obvious options are for it to belong to `CastingPrecedence` (like the `is` operator), or the `ComparisonPrecedence` (like the `==` operator):

```swift
precedencegroup ComparisonPrecedence {
  higherThan: LogicalConjunctionPrecedence
}
precedencegroup NilCoalescingPrecedence {
  associativity: right
  higherThan: ComparisonPrecedence
}
precedencegroup CastingPrecedence {
  higherThan: NilCoalescingPrecedence
}
```

These result in the same groupings for most common operators:

```swift
!a is case b // (!a) is case b

a is case b || c is case d // (a is case b) || (c is case d)
a is case b && c is case d // (a is case b) || (c is case d)

a is case b ? c is case d : e is case f // (a is case b) ? (c is case d) : (e is case f)

a is case b ..< c // a is case (b ..< c)
```

Only these operators would be affected:

```swift
a is case b == c 
a is case b == c is case d
a is case b != c is case d

a ?? b is case c
a is case b ?? c

a is case b is Bool
```

If `is case` were in `ComparisonPrecedence`, the above examples would be grouped as:

```swift
a is case b == c // 🛑 Error: adjacent operators are in non-associative precedence group 'ComparisonPrecedence'
a is case b == c is case d // 🛑 Error: adjacent operators are in non-associative precedence group 'ComparisonPrecedence'

(a ?? b) is case c
a is case (b ?? c)

a is case (b is Bool)
```

But if `is case` were in `CastingPrecedence`, the above examples would be grouped as:

```swift
(a is case b) == c
(a is case b) == (c is case d)
(a is case b) != (c is case d)

a ?? (b is case c)
(a is case b) ?? c

a is case b is Bool // 🛑 Error: adjacent operators are in non-associative precedence group 'CastingPrecedence'
```

We propose including the `is case` operator in `CastingPrecedence`, for several reasons:
 1. By analogy to the `is` operator, it seems reasonable to include `is case` in the same precedence group. 
 2. Enabling inline usage of the `==` operator seems most useful, of the above differences between the two groups. This also matches the grouping of other boolean operators like `||` and `&&`, so feels natural.
 3. Using `is` and `is case` together in a single expression is likely to be very uncommon, so doesn't need to be prioritized.
 4. Neither grouping of `??` is obviously more correct than the other

## Future directions

### Accessing enum associated values with `as case`

Another missing feature for working with enums is the ability to succinctly extract the payload of associated values from an enum value. A nautral extension to the proposed `is case` syntax could be a new `as case` syntax:

```swift
let destination = Destination.messageThread(id: 42)
let id = destination as case .messageThread // Optional<Int>(42)

let destination = Destination.profile(id: 42, edit: true)
let isEditing = (destination as case .profile)?.edit // Optional<Bool>(true)
```

This pair of `is case` and `as case` operators would be symmetrical to similar uses of `is` and `as` for type casting. If this proposal is accepted, we should explore adding the `as case` in a future proposal.

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

Using `is case` syntax in this way is potentially an improvement over `if case` syntax, since `if case` syntax is well-known for having poor autocomplete support. This is an interesting directly to explore in future proposals. We propose excluding this functionality from this propoal, however, since it is purely additive and can be added later.

It's not totally clear if this would be a good idea or not, since it would be inconsistent and potentially surprising for `is case` expressions to support different functionality depending on the context:

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

Since this functionality is already supported by `if case` syntax, it may not be ideal to have two different spellings of the same exact feature. While it might be forward-looking to replace `if case` syntax with an improved alternative, this likely wouldn't be worth the high amount of source churn.

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

### Case-specific computed properties

Another approach could be to synthesize computed properties for each enum case, either using compiler code synthesis or a macro.

For example, for  `case foo(bar: Int, baz: Int)` we could synthesize some or all of the following computed instance properties:
- `isFoo: Bool`
- `asFoo: (bar: Int, baz: Int)?`
- `bar: Int?`
- `bar: Int (if every case has a field bar: Int)`

This would handle the most common use for `is case`, checking if a value with known enum type has a particular case. However, it does not cover all of the use cases, such as matching patterns, and nested / partial values.

This also is a less appealing option for a potential related `as case` operator, where enums cases without associated values would require generating unidomatic `asCase: Void?` properties:

```swift
enum Destination {
  case inbox
  case settings
  case profile
}

// Synthesized properties:
extension Destination {
  // Idiomatic and reasonable:
  var isInbox: Bool { ... }
  var isSettings: Bool { ... }
  var isProfile: Bool { ... }

  // Not idomatic, and not really useful:
  var asInbox: Void? { ... }
  var asSettings: Void? { ... }
  var asProfile: Void? { ... }
}
```

Littering all of these mostly-useless, unidiomatic properties on a large number of enums seems less than ideal. Alternatively we could simply not generate these properties for enum cases without associated values, but this would likely result in confusing / surprising situations (e.g. that `value.asCase == nil` would work for some enum cases but not others). Since any option we choose for the `is case` operation would ideally extend nicely to a future `as case` operation, this seems like a compelling reason to prefer a different solution like the `is case `operator`.

When it comes to actually synthesizing these properties, there are a few different options, each with a their own set of trade-offs:

#### 1. Macro

We could add a macro to the standard library that, when applied to an enum declaration, generates code for these computed properties. One potential implementation of this macro is available [here](https://github.com/DougGregor/swift-macro-examples/blob/main/MacroExamplesPlugin/CaseDetectionMacro.swift), and generates the following code:

```swift
@CaseDetection // opt-in macro
enum Destination {
  case inbox
  case messageThread(id: Int)
}

// Generated code:
extension Destination {
  var isInbox: Bool { ... }
  var isMessageThread: Bool { ... }
}
```

This is convenient since it doesn't require adding any new concepts to the language. But even if the macro was defined in the standard library, actually adopting the macro on your enum is op-in. If we used a macro to provide this functionality, it would only be usable in cases where the author of the enum declaration opted-in. `is case` is a fundamental operation for working with enums, and would ideally be available for all enums by default.

#### 2. Automatic code generation

Another option could be for the compiler itself to generate these properties for all enums. This would enable the functionality for all enums by default, but at the cost of a substantial code size increase.

#### 3. Dynamically synthesized properties

If we wanted to have this enabled by default for all enums, but without actually generating properties for each case, we could dynamically synthesize these properties and inline their implementation. At the call site this would work similarly to `@dynamicMemberLookup`. This would be the most promising approach, but is probably a bit too "magic" for such a core language feature like this.

### Alternative spellings

Some potential alternative spellings for this feature include:

```swift
// <expr> matches <pattern>
// New keyword addition to the language
HeaderView(inThread: destination matches .messageThread)

// <expr> case <pattern> 
// Not evocative of a boolean condition
HeaderView(inThread: destination case .messageThread)

// <expr> is <pattern>
// Less clearly related to pattern matching (always indicated by `case` elsewhere in the language)
HeaderView(inThread: destination is .messageThread)

// case <pattern> = <expr>
// Consistent with the existing `if case`, but not evocative of a boolean condition.
HeaderView(inThread: case .messageThread = destination)

// <expr> == <pattern>
// Special case support for a specific operator. 
// Could be confusing to overload == with multiple different types of conditions.
// Ambiguous for enum cases without assoicated values (does it call the user-defined Equatable implementation, or the built-in pattern matching implementation?)
HeaderView(inThread: destination == .messageThreadd)

// <expr>.isCase(<pattern>)
// Magic operator that looks like a function but isn't, since patterns can't be used as function arguments
HeaderView(inThread: destination.isCase(.messageThread(_)))

// @isCase(<expr>, <pattern>)
// Potentially a macro defined in the standard library. 
// Not really idimatic, since it's like a global function rather than an infix operator.
HeaderView(inThread: @isCase(destination, .messageThread(_)))
```

Of these spellings, `<expr> is case <pattern>` is the best because:
1. it's clearly a condition that evaluates to a boolean
2. it includes the keyword `case` to indicate its relationship with existing pattern matching syntax (switch cases, `if case`)
3. it doesn't introduce conflicts or ambiguity with existing language features

The alternative keyword `matches` also came up in some early feedback in the context of an eventual more holistic change to make Swift's pattern matching syntax more approachable:

```swift
if destination matches .messageThread(let id) {
  // Do something with `id` here
}

switch destination {
  matches .messageThread(let id):
  // Do something with `id` here
  ...
}
```

The authors believe that such a change to Swift's pattern matching syntax warrants its own pitch/proposal and is out of scope for this current proposal. Even if such an eventual change is made, the addition of `is case` to the language would give us short-term consistency, instead of diverging Swift's syntax without guarantee of any future subsequent change.

## Acknowledgments

Andrew Bennett was the first person who suggested the spelling is case for this operation, way back in [2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2).

Alex Lew ([2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2)), Sam Dods ([2016](https://forums.swift.org/t/proposal-treat-case-foo-bar-as-a-boolean-expression/2546)), Tamas Lustyik ([2017](https://forums.swift.org/t/testing-enum-cases-with-associated-values/7091)), Suyash Srijan ([2018](https://forums.swift.org/t/comparing-enums-without-their-associated-values/18944)), Owen Voorhees ([2019](https://forums.swift.org/t/pitch-case-expressions-for-pattern-matching/20348)), Ilias Karim ([2020](https://forums.swift.org/t/proposal-sanity-check-assigning-a-case-statement-to-a-boolean/40584)), and Michael Long ([2021](https://forums.swift.org/t/enumeration-case-evaluates-as-boolean/54266)) have brought up this "missing feature" in the past, often generating good discussion. (There may have been more that we missed as well, and this isn't even counting "Using Swift" threads!)

Jon Hull ([2018](https://forums.swift.org/t/if-case-in/15000)), among others, for related discussion on restructuring if case.
