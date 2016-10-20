# Replace the `?:` operator with `.transformed(true:, false:)` on `Bool`

* Proposal: SE-NNNN
* Author: [Charlotte Tortorella](https://github.com/qata)
* Review Manager: TBD
* Status: Awaiting review

## Introduction

The ternary operator in Swift was added early in development, as a holdover
from C.  This document is an attempt to provide a clear look at the ternary
operator without the baggage of the languages that came before, and comes
to the conclusion that we should deprecate and remove the ternary operator
in favor of an extension to `Bool` as `transformed(true:, false:)`.

As a quick refresher, here's what the ternary operator looks like:

```swift
let a = 10
let b = 20
// If a is less than b, sets e to c, else sets e to d
let e = a < b ? "foo" : "bar"
```

## Advantages of The Ternary Operator

The primary advantage of this operator is its terseness and expressive
capability. It's shorthand for (e.g.):
```swift
let a = 10
let b = 20
let e: Int
if a < b {
  e = "foo"
} else {
  e = "bar"
}
```

The second advantage of Swift supporting the ternary operator is continuity
with C, and other common languages in the extended C family (C++, Objective-C,
Java, C#, Javascript, etc).  People coming to Swift from these other languages
may reasonably expect this operator to exist.  That said, there are also
popular languages which have kept the majority of C operators but dropped the
ternary operator (e.g. [Go](https://golang.org/doc/faq#Does_Go_have_a_ternary_form) and [Rust](https://github.com/rust-lang/rfcs/issues/1362)).


## Disadvantages of The Ternary Operator

1. The existence of the ternary operator as a holdover from C is to increase
the familiarity of the Swift language for C family developers, at the expense
of newcomers.  Established developers do much better with learning concepts
than newcomers to programming and probably don't need their hands held
with this holdover.

2. The ternary operator adds complexity to the compiler due to being the only
operator of its kind and needing special handling.

3. The ternary operator's usage of `?` can be confusing
to new users.  In every other instance of `?` it's associated with
Optional values.

4. The ternary operator also uses `:`, which is already a heavily overloaded
symbol in Swift. `:` is used in hash tables, type annotations to variables,
class inheritance and protocol conformance.

5. The ternary operator's short length lends it to being abused in the
nested ternary operator anti-pattern.  This is similar to how the `++` and `--`
operators worked fine and were readable enough on their own, but when used
multiple times in a single function call like `function(a++, ++a)`, they
were highly unreadable and confusing.

6. This operator is only applicable to a single type, `Bool`.

7. If the ternary operator did not already exist, I doubt it would be proposed
for Swift when higher clarity can be achieved with language features by
creating `transformed(true:, false:)`

8. There are similar sentiments in other languages that have special constructs
that could be handled in-language, such as [`if then else` in Haskell](https://wiki.haskell.org/If-then-else#Is_If-Then-Else_so_important.3F).
`if then else` is almost identical to the `?:` operator, the exception being
that it's prefixed by `if`, while `?:` has no prefix.
Example:
```haskell
if True then 10 else 20
```


## Proposed Approach

We should drop the ternary operator in favor of a new extension to `Bool`.
```swift
extension Bool {
    /// If `self == true`, returns `t`, otherwise, returns `f`.
    func transformed<T>(true t: @autoclosure () -> T, false f: @autoclosure () -> T) -> T {
        if self {
            return t()
        } else {
            return f()  
        }
    }
}
```

Example usage:
```swift
let a = 10
let b = 20
// If a is less than b, sets e to "foo", else sets e to "bar"
let e = (a < b).transformed(true: "foo", false: "bar")
```

## Alternatives considered

Simplest alternative: we could leave the ternary operator as is and not
introduce any new concepts.

It'd also be possible to add an `if then else` Haskell-esque expression.
This would have the disadvantages of still needing special handling by the
compiler.  Since this proposal's intention is partially to remove compiler
complexity, this would be counterproductive and would probably confuse new
users in a similar way to how `?:` does.
