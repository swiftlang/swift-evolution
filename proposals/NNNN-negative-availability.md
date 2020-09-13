# Unavailability Checks

* Proposal: [SE-NNNN](NNNN-negative-availability)
* Author: [Bruno Rocha](https://github.com/rockbruno)
* Review Manager: TBD
* Implementation: [apple/swift#33932](https://github.com/apple/swift/pull/33932)
* Status: **Awaiting review**

## Introduction

Checking whether a specific platform is **not** available is necessary when an API is *completely* different across versions. The most common example is how building an iOS app's main `UIWindow` changed with the introduction of `SceneDelegates`; While a basic `AppDelegate` app needs to setup its window when the app finishes launching, apps that support `SceneDelegate` should instead do it *later* in the app's lifecycle, more specifically, when the AppDelegate connects the app's main `UIScene`. This extreme difference in behavior cannot be conveyed by a simple if/else statement, instead requiring a *negative* check in the AppDelegate to indicate that you should only build the window if the user is **not** running iOS 13. Currently, this is only achievable through a workaround.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/support-negative-availability-literals/39946)

## Motivation

## Readability

Because the `#availability` literal is not parsed as an expression, it cannot be negated through regular means (`!`/`== false`). The current way to achieve a negative availability check is to make use of the the `else` portion of a regular check:

```swift
// if NOT in iOS 13, load the window.
// Post iOS 13, the window is loaded in the SceneDelegate.
if #available(iOS 13, *) {

} else {
  loadMainWindow()
}
```

However, as unavailability checks aren't interested in the *positive* portion of it, your code will end up with an empty block in the positive portion of the check.

With the exception of this very specific case, an empty statement is a sure sign that there's something wrong in the code. Every unavailability check is then likely to include a comment that indicates it was done on purpose due to the compiler's limitations, and it might even be necessary to disable your linters in the check's line as most would assume that this is a mistake and incorrectly attempt to fix it by negating the check, which as mentioned before cannot be done.

This workaround has a negative impact on the readability of the unavailability check. As shown below, most developers will attempt to hide the problem by putting the positive portion in a single line:

```swift
// if NOT in iOS 13, load the window.
// Post iOS 13, the window is loaded in the SceneDelegate.
if #available(iOS 13, *) {} else {
  loadMainWindow()
}
```

Unfortunately, this makes it easy to mistake it for a regular availability check. If the comment isn't clear enough about the logic being reversed on purpose, problems involving this check could easily land unnoticed. A less noisy way would be to put it under a `guard`:

```swift
guard #available(iOS 13, *) else {
  loadMainWindow()
  return
}
// no-op
```

However, this goes against the code style recommendations involving the usage of `guard`. The guarded part should be the happy path, which can never be the case in this context.

As seen, it's currently impossible to write an unavailability check that property fits a developer's expectations and Swift's general style guide.

## Code Structure

Besides the cases where having an unavailability check is mandatory, supporting them would give developers more options when structuring their code in cases where they are not. By not being forced to consider the availability of something as the happy path, developers would have more choices when considering how to architect and abstract certain pieces of code.

## Proposed solution

We would like to improve the readability of unavailability checks by properly supporting the ability to negate an availability check.

The proposal is to add the `#unavailable` literal:

```swift
if #unavailable(iOS 13, *) {
  loadMainWindow()
}
```

As dictated by the name, `#unavailable` is the reverse version of `#available`. Having a proper unavailability check will eliminate the need to use the current workaround and makes it clear to the reader that the statement is checking for the *lack* of a specific version, eliminating the need to provide a comment explaining what that piece of code is trying to achieve.

Like with `#available`, `#unavailable` has the capacity to increase the symbol availability of a scope. As opposed to `#available`, the availability is increased at the false portion of the check.

```swift
if #unavailable(iOS 13, *) {
  // Symbol Availability: Default (deployment target)
} else {
  // Symbol Availability: iOS 13
}
```

## Detailed design

As the compiler is already able to calculate the symbol availability for both the positive and negative flows of the check, implementing `#unavailable` is simply a matter of introducing a new keyword that reverses them. This allows `#unavailable` to be internally implemented as a simple boolean that flips `#available's` functionality.

Implementation: [apple/swift#33932](https://github.com/apple/swift/pull/33932)

### Preventing impossible conditions

The ability to use several availability checks in a single statement allows positive and negative availability checks to be mixed. This will lead to an ambiguous symbol availability:

```swift
// User running something between iOS 9 and 12
if #available(iOS 9.0), #unavailable(iOS 13.0) {
  // Symbol Availability: iOS 9.0
} else {
  // Symbol Availability: ???
}
```

The availability of the else block cannot be determined because it depends on which of the two conditions is false. To prevent this from happening, the compiler will emit a diagnostic whenever this happens.

```swift
if #available(iOS 9.0), #unavailable(iOS 13.0)
// error: #available and #unavailable cannot be in the same statement
```

Technically we could support this by *not* improving the symbol availability of a scope if it's ambiguous, but as there are currently no legitimate cases where one would have to mix availability with unavailability, the author believes the work necessary to support this and its edge cases is not worth it at the time this proposal was written. However, you can still use them as separate statements.

```swift
if #available(iOS 9.0) {
  // Symbol Availability: iOS 9.0
  if #unavailable(iOS 13.0) {
    // Symbol Availability: iOS 9.0
  } else {
    // Symbol Availability: iOS 13.0
  }
} else {
  // Symbol Availability: Default (deployment target)
}
```

As they are separate statements, there's no ambiguity.

### Function Builders

As `#unavailable` behaves exactly like `#available`, `ViewBuilder` does not need to be modified to support it. Using `#unavailable` on a builder will simply instead trigger `buildLimitedAvailability(_:)` in the `else` block. 

## Source compatibility and ABI

This change is purely additive.

## Alternatives considered

### `!#available(...)` and `#available(...) == false`

The first iteration of this proposal involved using the same availability keyword that exists today and simply allow it to be reversed. However, as `#available` is not coded as an expression, doing so would require hardcoding all of this behavior. While `== false` is trivial to include, `!` would require a few workarounds. The author would rather not add tech debt to the compiler.
