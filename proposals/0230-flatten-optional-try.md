# Flatten nested optionals resulting from 'try?'

* Proposal: [SE-0230](0230-flatten-optional-try.md)
* Author: [BJ Homer](https://github.com/bjhomer)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5)**
* Implementation: [apple/swift#16942](https://github.com/apple/swift/pull/16942)
* Review: ([forum thread](https://forums.swift.org/t/se-0230-flatten-nested-optionals-resulting-from-try/16570)) ([acceptance](https://forums.swift.org/t/accepted-se-230-flatten-nested-optionals-resulting-from-try/17376))

## Introduction

Swift's `try?` statement currently makes it easy to introduce a 
nested optional. Nested optionals are difficult for users to reason
about, and Swift tries to avoid producing them in other common cases.

This document proposes giving `try?` the same optional-flattening
behavior found in other common Swift features, to avoid the common
occurrence of a nested optional.

Swift-evolution thread: [Make try? + optional chain flattening work together](https://forums.swift.org/t/make-try-optional-chain-flattening-work-together/7415)

## Motivation

It's currently quite easy to end up with a nested `Optional` type when 
using `try?`. Although it is valid to construct a nested optional, it
is usually not what the developer intended.

Swift has various mechanisms to avoid accidentally creating nested optionals. For example:

```swift
// Note how 'as?' produces the same type regardless of whether the value
// being cast is optional or not.
let x = nonOptionalValue() as? MyType    // x is of type 'MyType?'
let y = optionalValue() as? MyType       // y is of type 'MyType?'

// Note how optional chaining produces the same type whether or not the
// call produces an optional value.
let a = optThing?.pizza()             // a is of type 'Pizza?'
let b = optThing?.optionalPizza()     // b is of type 'Pizza?'
```

However, `try?` behaves differently:

```swift
let q = try? harbor.boat()           // q is of type 'Boat?'
let r = try? harbor.optionalBoat()   // r is of type 'Boat??'
```

The above examples are contrived, but it's actually quite common to end
up with a nested optional in production code. For example:

```swift
// The result of 'foo?.makeBar()' is 'Bar?' because of the optional
// chaining on 'foo'. The 'try?' adds an additional layer of 
// optionality. So the type of 'x' is 'Bar??'
let x = try? foo?.makeBar()

// JSONSerialization.jsonObject(with:) returns an 'Any'. We use 'as?' to 
// verify that the result is of the expected type, but the result is that 'dict' 
// is now of type '[String: Any]??' because 'try?' added an additional layer.
let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
```

Although it is fairly easy to produce a nested optional using `try?`, a survey of
existing code suggests that it is almost never the desired outcome. Code that uses
`try?` with nested optionals is almost always accompanied by one of the following patterns:

```swift
// Pattern 1: Double if-let or guard-let
if  let optionalX = try? self.optionalThing(),
    let x = optionalX {
    // Use 'x' here
}

// Pattern 2: Introducing parentheses to let 'as?' flatten for us
if let x = (try? somethingAsAny()) as? JournalEntry {
    // use 'x' here
}

// Pattern 3: Pattern matching
if case let x?? = try? optionalThing() {
    // use 'x' here
}
```

The need for these workarounds makes the language more difficult to
learn and use, and they don't really give us any benefit in return.

Code using `try?` generally does not care to distinguish between the error case
and the nil-result case, which is why all these patterns focus on extracting the
value and ignore the error. If the developer does care to specifically detect errors, 
they should probably be using `do/try/catch` instead.

## Proposed solution

In Swift 5, `try? someExpr()` will mirror the behavior of `foo?.someExpr()`: 

- If `someExpr()` produces a non-optional value, it will be wrapped in an Optional.
- If `someExpr()` produces an `Optional`, then no additional optional-ness is added.

This results in the following changes to the type of a `try?` expression:

```swift
// Swift 4: 'Int??'
// Swift 5: 'Int?'
let result = try? database?.countOfRows(matching: predicate)


// Swift 4: 'String??'
// Swift 5: 'String?'
let myString = try? String(data: someData, encoding: .utf8)
    
// Swift 4: '[String: Any]??'
// Swift 5: '[String: Any]?'
let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
```

There are no changes to the overall type when the sub-expression produces a non-optional.

```swift 
// Swift 4: 'String?'
// Swift 5: 'String?'
let fileContents = try? String(contentsOf: someURL)
```

If the sub-expression already produces a nested optional, the result is equally
nested:

```swift
func doubleOptionalInt() throws -> Int?? {
    return 3
}

// Swift 4: 'Int???'
// Swift 5: 'Int??'
let x = try? doubleOptionalInt()
```

> ### A side note about `try?` and `as?`
> 
> Although `as?` often has the effect of flattening Optionals (as shown in 
> the example in the Motivation section) it does not exhibit exactly
> the same behavior as proposed here for `try?`. Because `as?` takes
> an explicit type, it can actually flatten multiple levels of nested
> Optionals. `foo as? T` will always produce an `Optional<T>`, regardless
> of how many optionals were on `foo`. This can potentially _add or subtract_
> levels of optionals, depending on the type specified. (It can also cast between
> subtypes and supertypes, which is unrelated to the behavior under consideration.)
> 
> In practice, the most common use of `as?` with nested optionals is to reduce from
> `T??` to `T?`, which makes it superficially similar to the use optional-chaining
> use case and the proposed behavior of `try?`. But `as?` is a more powerful
> and versatile construct than what is proposed for `try?` here.


## Detailed design

The type of a `try?` expression in Swift 4 is defined as `Optional<T>`,
where `T` is the type of the expression following the `try?` keyword.

In Swift 5, the type of a `try?` expression will be some type `U`, where
`U` is an `Optional<_>` type and where the sub-expression type `T` is 
coercible to `U`. The type constraint system automatically chooses the
smallest level of optional-nesting needed to satisfy this constraint, 
which results in the behavior described in this proposal.

#### Generics

Some questions have been raised regarding the interoperability with
generic code, as in the following example:

```swift
func test<T>(fn: () throws -> T) -> T? {

    // Will this line change behavior if T is an Optional?
    if let result = try? fn() {
        print("We got a result!")
        return result
    }
    else {
        print("There was an error")
        return nil
    }
}

// T is inferred as 'Int' here
let value  = test({ return 15 })

// T is inferred as 'Int?' here
let value2 = test({ return 15 as Int? })
```

The answer is that it does not matter if `T` is optional at runtime.
At compile time, `result` has a clearly-defined type: `T`. This is 
true in both Swift 4 and Swift 5 modes; because `T` is not known to be
an `Optional` type at compile-time, a single layer of `Optional` is added 
via the `try?` expression and then unwrapped via `if let`.

Generic code that uses `try?` can continue to use it as always without
concern for whether the generic type might be optional at runtime. No
behavior is changed in this case.


## Source compatibility

This is a source-breaking change for `try?` expressions that operate on an
`Optional` sub-expression _if they do not explicitly flatten the optional 
themselves_. It appears that those cases are rare, though; see the analysis
below for details. We can provide backward-compatible behavior when the compiler
is running in Swift 4 mode, and a migration should be possible for most common 
cases.

The bar for including source-breaking changes in Swift 5 is high, but I believe
it passes the bar. These are the criteria listed in the swift-evolution README:

### 1. The current syntax/API must be shown to actively cause problems for users.
 
Nested optionals are a complex concept. They have value in the language, but their
use should be intentional. Currently, it's far too easy for beginners to create a
nested optional without understanding why, due to the current interaction of
`try?` and optional chaining or `as?` casting. 
 
Code that uses `try?` to actually detect errors is _more_ difficult to understand
than just using `try`. Compare:

```swift
// Using 'try?'
if let result = try? foo?.bar() {
    // Do something with 'result', which may be nil
    // even though we are in an 'if let'.
}
else {
    // There was an error, but we don't know what it is
}
```

```swift
// Using 'try/catch'
do {
    let result = try foo?.bar()
    // Do something with 'result', which may be nil due to optional chaining
}
catch {
    // Handle the error
}
```

The variant using `try?` is significantly less clear (what is the type of
`result`?), and has no obvious advantages. Using `try?` _is_ better if you
don't care about the _else_ clause and only want to handle a value if one
exists, but that use case is better served by the proposed change.

The current syntax is also harmful because of its interaction with `as?` casting,
as seen here:

```swift
if let x = try? foo() as? String {
    // We specifically called out `String` as the desired type here,
    // so it unexpected that `x` is of type `Optional<String>`
}
```

### 2. The new syntax/API must be clearly better and must not conflict with existing Swift syntax.

The proposed change resolves all of the above problems, which is better.
This change also clarifies the role of `try?` as a means for accessing 
values when possible, rather than as an alternative error-handling 
mechanism to `try/catch`.

### 3. There must be a reasonably automated migration path for existing code.

As shown in the analysis below, most source code will require no migration; 
developers who have encountered code that produces nested Optionals are likely
already using patterns that are source-compatible with this change. This proposal
simply provides a way to simplify that code.

Automated migration is implemented for the double `if/guard let` and 
`case let value??:` patterns mentioned above.

## Swift Source Compatibility Suite analysis

The Swift Source Compatibility Suite suggests that this is unlikely to 
be a breaking change for most users. I manually inspected the use
cases of `try?` in the compatibility suite. Here are the results:

* There are **613** total instances of `try?` in the compatibility suite. The vast majority of those appear to use non-optional sub-expressions, and would be unaffected by this proposal.

* There are **4** instances of `try? ... as?`. All four of them wrap the `try?` in parentheses to get the flattening behavior of `as?`, and are source-compatible with this change. They all look something like this:

    ```swift
    (try? JSONSerialization.jsonObject(with: $0)) as? NSDictionary
    ```

* There are **12** cases of `try? foo?.bar()` across 3 projects.
**10** of those assign it to `_ = try? foo?.bar()` , so the resulting type does not matter.
**2** of those cases have a `Void` sub-expression type, and do not assign the result to any variable.

* There are **6** instances of `try? somethingReturningOptional()` . They all flatten it manually using `flatMap { $0 }`, and are thus source-compatible with this change, as the return type of that expression is the same under either behavior.

    ```swift
    (try? get(key)).flatMap { $0 }
    ```

* As far as I can tell, there are **zero** cases in the entire suite where a double-optional is actually used to distinguish between the error case and the nil-as-a-value case.

* As far as I can tell, there are **zero** cases of source incompatibility found in the compatibility suite.


## Effect on ABI stability

No impact on ABI.

## Effect on API resilience

A `try?` expression is never exposed at function boundaries, so API
resilience should be unaffected.

## Alternatives considered

### Alter the binding precedence of try?

For expressions like `let x = try? getObject() as? Foo`, the nested optional 
can be eliminated by parsing the expression as `(try? getObject) as? Foo`. 
Adding explicit parentheses like this is already a common workaround for 
the double-optional problem.

However, this change would not resolve cases of `try?` with optional chaining
(e.g. `try? foo?.bar?.baz()`), nor cases where an optional result is returned
directly from a function (e.g. `try? cachedValue(for: key)`). 

Altering the binding precedence of `try?` would also be *far* more 
source-breaking than this proposal.

### Do nothing

It is possible to write correct code under the current model. We are not 
proposing to eliminate nested Optionals from the language entirely, so 
we could just expect users to figure them out.

This is a workable solution, but it is odd to have such a complex structure
produced as part of a syntactic sugar designed to simplify a common case.
