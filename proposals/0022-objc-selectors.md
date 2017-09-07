# Referencing the Objective-C selector of a method

* Proposal: [SE-0022](0022-objc-selectors.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Implemented (Swift 2.2)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160125/007797.html)
* Implementation: [apple/swift#1170](https://github.com/apple/swift/pull/1170)

## Introduction

In Swift 2, Objective-C selectors are written as string literals
(e.g., `"insertSubview:aboveSubview:"`) in the type context of a
`Selector`. This proposal seeks to replace this error-prone approach
with `Selector` initialization syntax that refers to a specific method
via its Swift name.

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006282.html), [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/006913.html), [Amendments after acceptance](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/018698.html)

## Motivation

The use of string literals for selector names is extremely
error-prone: there is no checking that the string is even a
well-formed selector, much less that it refers to any known method, or
a method of the intended class. Moreover, with the effort to perform
[automatic renaming of Objective-C
APIs](0005-objective-c-name-translation.md),
the link between Swift name and Objective-C selector is
non-obvious. By providing explicit "create a selector" syntax based on
the Swift name of a method, we eliminate the need for developers to
reason about the actual Objective-C selectors being used.

## Proposed solution

Introduce a new expression `#selector` that allows one to build a selector from a reference to a method, e.g.,

```swift
control.sendAction(#selector(MyApplication.doSomething), to: target, forEvent: event)
```

where “doSomething” is a method of MyApplication, which might even have a completely-unrelated name in Objective-C:

```swift
extension MyApplication {
  @objc(jumpUpAndDown:)
  func doSomething(sender: AnyObject?) { … }
}
```

By naming the Swift method and having the `#selector` expression do
the work to form the Objective-C selector, we free the developer from
having to do the naming translation manually and get static checking
that the method exists and is exposed to Objective-C.

This proposal composes with the [Naming Functions with Argument Labels
proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006262.html), which lets us name methods along with their argument labels, e.g.:

	let sel = #selector(UIView.insertSubview(_:atIndex:)) // produces the Selector "insertSubview:atIndex:"

With the introduction of the `#selector` syntax, we should deprecate
the use of string literals to form selectors. Ideally, we could
perform the deprecation in Swift 2.2 and remove the syntax entirely
from Swift 3.

Additionally, we should introduce specific migrator support to
translate string-literals-as-selectors into method references. Doing
this well is non-trivial, requiring the compiler/migrator to find all
of the declarations with a particular Objective-C selector and
determine which one to reference. However, it should be feasible, and
we can migrate other references to a specific, string-based
initialization syntax (e.g., `Selector("insertSubview:atIndex:")`).

## Detailed design

The subexpression of the `#selector` expression must be a reference to an `objc` method. Specifically, the input expression must be a direct reference to an Objective-C method, possibly parenthesized and possibly with an "as" cast (which can be used to disambiguate same-named Swift methods). For example, here is a "highly general" example:

```swift
let sel = #selector(((UIView.insertSubview(_:at:)) as (UIView) -> (UIView, Int) -> Void))
```

The expression inside `#selector` is limited to be a series of instance 
or class members separated by `.` where the last component may be 
disambiguated using `as`. In particular, this prohibits performing 
method calls inside `#selector`, clarifying that the subexpression of 
`#selector` will not be evaluated and no side effects occur because of it.

The complete grammar of `#selector` is:

<pre>
selector → #selector(<i>selector-path</i>)

selector-path → <i>type-identifier</i> . <i>selector-member-path</i> <i>as-disambiguation<sub>opt</sub></i>
selector-path → <i>selector-member-path</i> <i>as-disambiguation<sub>opt</sub></i>

selector-member-path → <i>identifier</i>
selector-member-path → <i>unqualified-name</i>
selector-member-path → <i>identifier</i> . <i>selector-member-path</i>

as-disambiguation → as <i>type-identifier</i>
</pre>

## Impact on existing code

The introduction of the `#selector` expression has no
impact on existing code. However, deprecating and removing the
string-literal-as-selector syntax is a source-breaking
change. We can migrate the uses to either the new `#selector`
expression or to explicit initialization of a `Selector`
from a string.

## Alternatives considered

The primary alternative is [type-safe
selectors](https://lists.swift.org/pipermail/swift-evolution/2015-December/000233.html),
which would introduce a new "selector" calling convetion to capture
the type of an `@objc` method, including its selector. One major
benefit of type-safe selectors is that they can carry type
information, improving type safety. From that discussion, referencing
`MyClass.observeNotification` would produce a value of type:

```swift
@convention(selector) (MyClass) -> (NSNotification) -> Void
```

Objective-C APIs that accept selectors could provide type information
(e.g., via Objective-C attributes or new syntax for a typed `SEL`),
improving type safety for selector-based APIs. Personally, I feel that
type-safe selectors are a well-designed feature that isn't worth
doing: one would probably not use them outside of interoperability
with existing Objective-C APIs, because closures are generally
preferable (in both Swift and Objective-C). The cost of adding this
feature to both Swift and Clang is significant, and we would also need
adoption across a significant number of Objective-C APIs to make it
worthwhile. On iOS, we are talking about a relatively small number of
APIs (100-ish), and many of those have blocks/closure-based variants
that are preferred anyway. Therefore, we should implement the simpler
feature in this proposal rather than the far more complicated (but
admittedly more type-safe) alternative approach.

Syntactically, `@selector(method reference)` would match Objective-C
more closely, but it doesn't make sense in Swift where `@` always
refers to attributes.

The original version of this proposal suggested using a magic
`Selector` initializer, e.g.:

```swift
let sel = Selector(((UIView.insertSubview(_:at:)) as (UIView) -> (UIView, Int) -
```

However, concerns over this being magic syntax that looks like
instance construction (but is not actually representable in Swift as
an initializer), along with existing uses of `#` to denote special
expressions (e.g., `#available`), caused the change to the `#selector`
syntax at the completion of the public review.

## Revision history

- 2016-05-20: The proposal was amended post-acceptance to limit the
syntax inside the subexpression of `#selector`, in particular disallowing 
methods calls. Originally any valid Swift expression was supported.
