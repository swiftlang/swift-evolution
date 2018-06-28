# Deprecate Strange Interpolations

* Proposal: [SE-NNNN](NNNN-strange-interpolations.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax)
* Review Manager: TBD
* Status: **Implemented**
* Implementation: [apple/swift#17587](https://github.com/apple/swift/pull/NNNNN)
* Bugs: [SR-7937](https://bugs.swift.org/browse/SR-7937),
        [SR-7958](https://bugs.swift.org/browse/SR-7958)

## Introduction

We propose deprecating several string interpolation syntaxes which were
unintentionally permitted by the Swift parser, such as `"\(x, y)"` and
`"\(foo: x)"`. Code using these constructs will emit warnings with
fix-its in Swift 4.2, and will be removed or interpreted differently
in a future version of Swift.

Swift-evolution thread: [Pitch: Deprecate strange interpolations in Swift 4.2][thread]

  [thread]: <https://forums.swift.org/t/pitch-deprecate-strange-interpolations-in-swift-4-2/13694>

## Motivation

The usual string interpolation syntax in Swift looks like this:

```swift
print("Hello, \(value)")
```

However, [during some experimental work in Swift's prehistory][lattner], the
parser was extended to treat an interpolation not as a single parenthesized
expression, but as an argument tuple. Although the feature it was supposed to
enable never materialized, this change stayed in the parser, and so Swift
will currently parse several other variants of string interpolation, such as:

```swift
print("Hello, \(name: value)")
print("Hello, \(value1, value2)")
print("Hello, \(name: value1, nominus: value2)")
```

All three of these implicitly form a tuple and interpolate it. Since the first variant
forms an illegal single-element tuple, it previously would often cause crashes or
strange errors later in compilation; in Swift 4.2 it reliably interpolates the value
as though the label was not present. The second and third variants create a
multiple-element tuple and interpolate its debugging representation, which includes
parentheses and labels and formats values differently from a normal interpolation.

The first variant is obviously useless; the second and third could be occasionally
useful in logging, but cover very marginal use cases. We are now [designing a 
feature similar to the one the parsing change was intended to support][new-interpolation],
but the new feature will probably make any existing uses stop compiling, and even
those that *do* compile will behave differently from before.

Neither syntax has ever been documented, and there are no examples of them in the
source compatibility suite. However, Apple is aware of some closed-source code which
*does* use them successfully, so they cannot be removed without an evolution
proposal.

  [lattner]: <https://forums.swift.org/t/pitch-deprecate-strange-interpolations-in-swift-4-2/13694/10>
  [new-interpolation]: <https://forums.swift.org/t/string-interpolation-revamp-design-decisions/12624>

## Proposed solution

We will emit deprecation warnings and fix-its for interpolations with multiple
elements or argument labels. When multiple elements are present, the fix-its
will insert an extra set of parentheses; when one labeled element is present,
it will remove the label. In either case, applying the fix-it will preserve the
current behavior in a forward-compatible way.

To encourage all users to apply the trivial changes needed to migrate, the
warning will be emitted in all version modes.

The exact wording of the diagnostics will not be specified by this proposal,
but the current implementation uses warnings like:

```
warning: labeled interpolations will not be ignored in future versions of Swift
print("'\(describing: name)'")
          ^
note: remove 'describing' label to keep current behavior
print("'\(describing: name)'")
          ^~~~~~~~~~~~
warning: interpolating multiple values will not form a tuple in future versions of Swift
debugPrint("at \(length: length, offset: offset)")
                                 ^
note: insert parentheses to keep current behavior
debugPrint("at \(length: length, offset: offset)")
                 ^                             ^
                 (                             )
```

## Source compatibility

This proposal is basically a gentle transition in anticipation of a
source-breaking change in the future. Very few people are using this
syntax; this proposal very politely tells those few to step aside.

Existing uses will still compile and run with the same behavior as before
in Swift 4.2, but a warning will now be emitted. The fix-its on that
warning only add or remove a handful of characters and precisely preserve
the old behavior. In some cases, code that caused compiler crashes in
previous versions will actually compile and emit a warning in Swift 4.2.

The deprecation warning proposed here will be maintained until at least
Swift 5, and we anticipate that its Swift 4.2 mode will continue to
function as described in this proposal--emitting warnings without
changing behavior.

## Effect on ABI stability

Almost none. The future interpolation proposal will affect ABI stability,
but we could delay the part that would conflict with this proposal with
a negligible effect on the standard library's ABI—basically, we might
need a couple extra overloads.

## Effect on API resilience

None.

## Future directions

### Single-element tuples

There has recently been some discussion in the Evolution forum about
permitting tuples containing a single element. While that change would
make the behavior of the single-element variant of this syntax more
sensible, we think this proposal should be accepted whether or not we
choose to support single-element tuples in the future.

### Our intentions for this syntax

As a preview we will briefly sketch our plans for this syntax in a future
version of Swift. We are not proposing what's described in this section
yet--it's still in development and some details may change.

In the future, we intend to introduce a public protocol that types may
conform to if they want to be expressible by string literals containing
interpolations. Each literal portion of the string literal will be 
translated into a call to an `appendLiteral` method, while each 
interpolated portion will be translated into a call to an 
`appendInterpolation` method.

We intend to allow multiple overloads of the `appendInterpolation` method,
supporting nearly any parameter signature. The `\(...)` of an interpolation
will be treated as an argument list, so an interpolation with multiple values
in it will turn into multiple arguments, and an interpolation with labeled
values will turn into labeled arguments.

Some things we imagine users might do with this feature:

```swift
// Formatting options for specific types:
print("Commit number \(bigint, radix: 16)")

// Types which automatically escape values interpolated into them:
let message: HTML = """
          <p>
            Hello, \(user.name)! We've recently updated our privacy
            policy because our lawyers insisted. Please click the
            button below to consent!
          </p>
          <p>
            \(rawHTML: makeConsentButton(for: user))
          </p>
          """
// If user.name is "<script>stealPrivateData()</script>", it'll end
// up interpolating "&lt;script&gt;stealPrivateData()&lt;/script&gt;"

// Types which only allow certain types to be interpolated:
SQLStatement("SELECT * FROM users WHERE id = \(user.id)") // okay
SQLStatement("SELECT * FROM users WHERE id = \(user)")    // error, can't take User
```

Again, this code sample shows something we're *thinking about* supporting.
The proposal you're reading today merely clears the way for us to eventually
add these interpolation features if we choose to do so later. Even if we never
do that, we think this odd and inconsistent corner of the language is in dire
need of a spring cleaning.

## Alternatives considered

* We could officially support the multiple-value-tuple version of the syntax.
  This would completely avoid ever breaking source compatibility, but would
  give up a desirable syntax for a marginal and unintended use case.

* We could make these constructs hard errors in Swift 4.2. This would break
  source compatibility for a small—but non-zero—number of projects in the
  wild.

* We could do nothing today and change the interpretation of these
  interpolations in Swift 5 without warning. This would be a source-breaking
  change for a small—but non-zero—number of projects in the wild, and
  users would not be able to transition by blindly trusting the fix-its.
