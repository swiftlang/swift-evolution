# Improved Syntax for Optionals of Opaque and Existential Types

* Proposal: [SE-NNNN](NNNN-improved-optional-opaque-and-any.md)
* Authors: [Tony Allevato](https://github.com/allevato)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#87115](https://github.com/swiftlang/swift/pull/87115), [swiftlang/swift-syntax#3268](https://github.com/swiftlang/swift-syntax/pull/3268)

## Summary of changes

Allows the types `some P?` and `any P?` to be written, having the same meaning as `(some P)?` and `(any P)?` respectively.

## Motivation

Swift supports opaque types written `some P` and explicit existential types written `any P`, for some protocol `P`. However, due to parsing precedence, combining these types with optional type sugar (`?` and its implicitly unwrapped version `!`) currently requires wrapping the type in parentheses, such as `(some P)?` or `(any P)?`.

Developers frequently attempt to write `some P?` or `any P?` due to familiarity with standard optional syntax (e.g., `Int?`, `String?`). These forms are currently rejected, because they are interpreted as `some (P?)` and `any (P?)`. The constraint following `some` or `any` must be a protocol, which `P?` (that is, `Optional<P>`), is not.

It is unlikely that a future version of Swift would ever define `some/any P?` to have a meaning other than what users would intuitively expect: an `Optional` of an opaque/existential type that conforms to `P`. However, a future version of Swift may **require** explicit `any` for existential types, meaning that there would likely be a proliferation of parentheses wherever optional existentials are used. Therefore, this simpler syntax improves ergonomics and readability.

## Proposed solution

We propose to make `some P?` equivalent to `(some P)?` and `any P?` equivalent to `(any P)?`.

This extends to multiple levels of optionality. For example, `some/any P??` will be equivalent to `(some/any P)??`, for any optionality depth.

Likewise, implicitly unwrapped optionals receive the same treatment wherever they are already supported. This proposal would make `any P!` equivalent to `(any P)!`.

Protocol compositions are also supported if the composition itself is wrapped in parentheses. Today, a developer must write `(any P & Q)?`. That would continue to be valid, but for consistency with the single constraint case, `any (P & Q)?` would also become valid. The same composition without parentheses, `any P & Q?`, would continue to be an error (see [Potentially confusing optional compositions](#potentially-confusing-optional-compositions) below).

## Detailed design

### Parser changes

The current type parser implements the following precedence relationships:

_Prec_(`?`) > _Prec_(`&`) > _Prec_({`some`, `any`})

We propose modifying these rules to hoist up a trailing optional `?`/`!` operator to encompass the entire `some`/`any` type. The following table shows how some examples parse today vs. how they would parse under the new rules in this proposal. The ✅ or ❌ next to each example indicates whether they are currently/will be valid Swift under the new rules.

| Example          | Current Parse               | Proposed Parse             |
|------------------|-----------------------------|----------------------------|
| `some P?`        | ❌ `some (P?)`              | ✅ `(some P)?`              |
| `some P & Q`     | ✅ `some (P & Q)`           | ✅ **same**                 |
| `some P & Q?`    | ❌ `some (P & (Q?))`        | ❌ `(some (P & Q))?`        |
| `some P? & Q`    | ❌ `some ((P?) & Q)`        | ❌ **same**                 |
| `some P?.R & Q`  | ✅ `some (((P?).R) & Q)`    | ✅ **same**                 |
| `some P?.R & Q?` | ❌ `some (((P?).R) & (Q?))` | ❌ `(some (((P?).R) & Q))?` |
| `some P?.R?`     | ❌ `some (((P?).R)?)`       | ✅ `(some ((P?).R))?`       |

#### Potentially confusing optional compositions

Note that under the new parsing rules, the spelling `some P & Q?` produces a parse tree that could be interpreted as an "optional of opaque type conforming to `P & Q`". We could allow this, but we consider it to be potentially confusing. Most readers of Swift would not expect a postfix operator `?` to encompass both an arbitrarily long protocol composition _and_ the keyword before it. We acknowledge that we _are_ proposing such an encompassing rule for the `some`/`any` keyword in cases like `some P?`, but we consider the longer form to be less clear due to additional intervening operators and whitespace.

Therefore, we will emit a specific diagnostic in the case where we see a `?` or `!` following a bare protocol composition, along with a fix-it to insert parentheses around the composition.

If practical experience in the future tells us that this limitation is too restrictive, then it can be revisited without causing any source breaks.

### Existential `any` fix-its

Compiler fix-its for explicit existential `any` no longer insert parentheses when the existential type is constrained to a single protocol (not a composition) and it is optional or implicitly unwrapped optional. For example, when the following code is compiled with `-enable-experimental-feature ExistentialAny` today:

```swift
let x: P?
```

it generates the following diagnostic and fix-it:

```
warning: use of protocol 'P' as a type must be written 'any P'; this will be an error in a future Swift language mode
    let x: P?
           ^~~~~~~
           (any P)
```

This proposal changes the fix-it replacement to be `any P` rather than `(any P)`.

## Source compatibility

This is a purely additive change to the valid syntax of the language. Code that previously failed to compile (e.g., `some P?`) will now compile with the expected semantics.

Existing code that explicitly uses parentheses (e.g., `(some P)?`) remains valid and semantically identical.

## Effect on ABI stability

This proposal has no effect on ABI stability. The types `some/any P?` and `(some/any P)?`—and thus their manglings—are identical.

## Effect on API resilience

This proposal has no effect on API resilience.

## Alternatives considered

**Do nothing**: We could continue requiring parentheses. However, this remains a common source of frustration for users adopting `some` and `any`.

## Acknowledgments

Thanks to the Swift team for their prior work on opaque and existential types.
