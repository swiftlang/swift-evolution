# Referencing the Objective-C selector of a method

* Proposal: [SE-0022](https://github.com/apple/swift-evolution/blob/master/proposals/0022-objc-selectors.md)
* Author(s): [Doug Gregor](https://github.com/DougGregor)
* Status: **Under review**
* Review manager: [Joe Groff](https://github.com/jckarter)

## Introduction

In Swift 2, Objective-C selectors are written as string literals
(e.g., `"insertSubview:aboveSubview:"`) in the type context of a
`Selector`. This proposal seeks to replace this error-prone approach
with `Selector` initialization syntax that refers to a specific method
via its Swift name.

Swift-evolution thread: [here](http://thread.gmane.org/gmane.comp.lang.swift.evolution/1384/focus=1403)

## Motivation

The use of string literals for selector names is extremely
error-prone: there is no checking that the string is even a
well-formed selector, much less that it refers to any known method, or
a method of the intended class. Moreover, with the effort to perform
[automatic renaming of Objective-C
APIs](https://github.com/apple/swift-evolution/blob/master/proposals/0005-objective-c-name-translation.md),
the link between Swift name and Objective-C selector is
non-obvious. By providing explicit "create a selector" syntax based on
the Swift name of a method, we eliminate the need for developers to
reason about the actual Objective-C selectors being used.

## Proposed solution

Introduce `Selector` initialization syntax that allows one to build a selector from a reference to a method, e.g.,

```swift
control.sendAction(Selector(MyApplication.doSomething), to: target, forEvent: event)
```

where “doSomething” is a method of MyApplication, which might even have a completely-unrelated name in Objective-C:

```swift
extension MyApplication {
  @objc(jumpUpAndDown:)
  func doSomething(sender: AnyObject?) { … }
}
```

By naming the Swift method and having the `Selector` initializer do
the work to form the Objective-C selector, we free the developer from
having to do the naming translation manually and get static checking
that the method exists and is exposed to Objective-C.

This proposal composes with the [Naming Functions with Argument Labels
proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006262.html), which lets us name methods along with their argument labels, e.g.:

	let sel = Selector(UIView.insertSubview(_:at:)) // produces the Selector "insertSubview:atIndex:"

With the introduction of the `Selector` syntax, we should deprecate
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

The proposed `Selector` initializer "almost" has the signature:

```swift
extension Selector {
  init<T, U>(_ fn: (T) -> U)
}
```

with some additional semantic restrictions that require that input be a reference to an `objc` method. Specifically, the input expression must be a direct reference to an Objective-C method, possibly parenthesized and possibly with an "as" cast (which can be used to disambiguate same-named Swift methods). For example, here is a "highly general" example:

```swift
let sel = Selector(((UIKit.UIView.insertSubview(_:at:)) as (UIView) -> (UIView, Int) -> Void))
```

The actual implementation will introduce some magic in the type
checker to only support references to methods within the `Selector`
initialization syntax.

## Impact on existing code

The introduction of the `Selector` initialization syntax has no
impact on existing code. However, deprecating and removing the
string-literal-as-selector syntax is a source-breaking
change. We can migrate the uses to either the new `Selector`
initialization syntax or to explicit initialization of a `Selector`
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
refers to attributes. `Selector` initialization syntax is far cleaner,
since we are constructing an instance of a `Selector`.
