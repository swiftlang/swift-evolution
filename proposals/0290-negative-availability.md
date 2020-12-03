# Unavailability Condition

* Proposal: [SE-0290](0290-negative-availability.md)
* Author: [Bruno Rocha](https://github.com/rockbruno)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Implementation: [apple/swift#33932](https://github.com/apple/swift/pull/33932)
* Status: **Returned for revision**
* Decision Notes: [Review #1](https://forums.swift.org/t/se-0290-unavailability-condition/41873/34)

## Introduction

Swift historically supported the `#available` condition to check if a specific symbol **is** available for usage, but not the opposite. In this proposal, we'll present cases where checking for the **unavailability** of something is necessary, the ugly workaround needed to achieve it today and how a new `#unavailable` condition can fix it.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/support-negative-availability-literals/39946)

## Motivation

Checking whether a specific platform/symbol is **not** available is necessary when the changes made to an API are so extreme that you cannot represent it in a single if/else statement. The most common example is how building an iOS app's main `UIWindow` changed with the introduction of `SceneDelegates`. While a basic iOS 12 `AppDelegate` app sets up its window when the app finishes launching, apps that support `SceneDelegates` should instead do it *later* in the app's lifecycle -- more specifically, when the AppDelegate connects the app's main `UIScene`. Since this happens outside the usual `didFinishLaunching` flow, this extreme difference in behavior cannot be conveyed by a simple if/else availability check. Instead, the `AppDelegate` will require a *negative* platform check that makes it sure it only sets up the window if the user is **not** running iOS 13:

```swift
// if NOT in iOS 13, load the window.
// Post iOS 13 the window is loaded later in the lifecycle, in the SceneDelegate.
if #available(iOS 13, *) {

} else {
  loadMainWindow()
}
```

### Readability

As you might notice, the current way to achieve negative availability checks is by working around the current `#available` keyword. Because the availability condition is not parsed as an expression, it cannot be negated with regular boolean operations (`!`/`== false`). The way instead is to make use of the `else` clause, but as unavailability checks are not interested at all in the positive portion of the check, doing so will leave behind an empty `if` branch. For context, this problem does not exist in Objective-C as `if (@available(iOS 13.0, *) == NO)` is a valid expression.

With the exception of this very specific case, an empty statement is a sure sign that there's something wrong in the developer's code, and it is likely that every unavailability check like this had to include a comment to indicate that it was done on purpose due to the compiler's limitations. In some cases, it might even be necessary to add an exclusion rule to the project's linters as most would assume that this is a mistake and incorrectly suggest that it can be fixed by negating the statement.

This workaround has a clear negative impact on the readability of the unavailability check, as no one would expect an empty `if` statement to not be a coding mistake. Most developers will attempt to hide the problem by putting the positive portion in a single line:

```swift
// if NOT in iOS 13, load the window.
// Post iOS 13 the window is loaded later in the lifecycle, in the SceneDelegate.
if #available(iOS 13, *) {} else {
  loadMainWindow()
}
```

Unfortunately, this makes it easy to mistake it for a regular availability check. If the comment isn't clear that the statement is wrong on purpose, problems involving this check could easily land unnoticed in code-reviews. A less noisy way would be to put it under a `guard`:

```swift
guard #available(iOS 13, *) else {
  loadMainWindow()
  return
}
// no-op
```

However, this goes against the code style recommendations involving the usage of `guard`. The guarded part should be the happy path, which is not the case when doing unavailability checks. As shown, it's currently impossible to write an unavailability check that properly fits a developer's engineering expectations and Swift's general style guide. 

Currently, any iOS application that supports UIScenes will face this issue and have to write this workaround. To describe it in a generic way, this issue will be encountered when dealing with any API addition or change that requires more than one availability condition to be implemented.

### Usage of deprecated APIs

A negative availability condition might also be necessary in cases where an API is marked as deprecated (and documented as non-functional) in newer OS versions.

An example is the deprecation of the [`isAdvertisingTrackingEnabled`](https://developer.apple.com/documentation/adsupport/asidentifiermanager/1614148-isadvertisingtrackingenabled) property. Apps supporting iOS 14 must now use the new App Tracking Transparency framework for user tracking purposes, which involves displaying a permission alert for the user that explains why they are going to be tracked. A developer might determine that this large change in functionality might warrant a complete refactor of this feature, or simply conclude that the negative UX of displaying a new alert is not worth it and that they should remove this feature entirely. In any case however, the property still works when used with older iOS versions:

```swift
// If NOT on iOS 14, track this action.
// Post iOS 14, we must ask for permission to do this.
// The UX impact is not worth it. Let's not do this at all.
if #available(iOS 14.0) {

} else {
  oldIos13TrackingLogic(isEnabled: ASIdentifierManager.shared().isAdvertisingTrackingEnabled)
}
```

In this specific case, a company that wants to adopt the new privacy practices will require unavailability checks to prevent breaking old versions of the app. In general, this will be the case when dealing with any API that is now deprecated.

### Code Structure

Besides cases where having an unavailability check is mandatory, supporting them would give developers more options when structuring their code in cases where they are not mandatory. By not being forced to consider the availability of something as the happy path, developers would have more choices when considering how to architect and abstract certain pieces of code.

## Proposed solution

Given that Objective-C is capable of negating availability checks, we believe that this not being supported in Swift was simply an oversight. We would like to propose this feature back to Swift in the shape of a new `#unavailable` condition: 

```swift
if #unavailable(iOS 13, *) {
  loadMainWindow()
}
```

As dictated by the name, `#unavailable` is the reverse version of `#available`. Having a proper unavailability check will eliminate the need to use the current workaround and makes it clear to the reader that the statement is checking for the *lack* of a specific version, eliminating the need to provide a comment explaining what that piece of code is trying to achieve.

Like with `#available`, `#unavailable` has the capacity to increase the symbol availability of a scope. As opposed to `#available`, the availability is increased at the `else` clause.

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
if #available(iOS 9.0, *), #unavailable(iOS 13.0, *) {
  // Symbol Availability: iOS 9.0
} else {
  // Symbol Availability: ???
}
```

The availability of the else block cannot be determined because it depends on which of the two conditions is false. To prevent this from happening, the compiler will emit a diagnostic whenever this happens.

```swift
if #available(iOS 9.0, *), #unavailable(iOS 13.0, *)
// error: #available and #unavailable cannot be in the same statement
```

Technically we could support this by *not* improving the symbol availability of a scope if it's ambiguous, but as there are currently no legitimate cases where one would have to mix availability with unavailability, the author believes the work necessary to support this and its edge cases is not worth it at the time this proposal was written. However, you can still use them as separate statements.

```swift
if #available(iOS 9.0, *) {
  // Symbol Availability: iOS 9.0
  if #unavailable(iOS 13.0, *) {
    // Symbol Availability: iOS 9.0
  } else {
    // Symbol Availability: iOS 13.0
  }
} else {
  // Symbol Availability: Default (deployment target)
}
```

As they are separate statements, there's no ambiguity.

### Multiple Elses

In the case of multiple else flows, the compiler will increase the symbol availability in **all** of them.

```swift
if #unavailable(iOS 9.0, *) {
  // Symbol Availability: Default (deployment target)
} else if a == b {
  // Symbol Availability: iOS 9.0
} else if b == c {
  // Symbol Availability: iOS 9.0
} else {
  // Symbol Availability: iOS 9.0
}
```

### Semantics of `*`

The compiler uses the platform wildcard `*` to ease porting to new platforms. Because new platforms typically branch from existing platforms, the wildcard allows availability checks to execute the guarded branch on the new platform without requiring a modification to every availability guard in the program. 

To achieve this in practice, the wildcard represents the minimum deployment target of the unspecified platform being compiled.

```swift
if #available(*) {
  // ...
} else {
  // Will never be executed
}
```

When multiple platforms are present in the statement, the wildcard represents *only* the platforms that were not specified. A check like `#available(iOS 13, *)` means "if compiling for iOS, iOS 13, otherwise, the minimum deployment target" and not "if compiling for iOS, iOS 13 **and** iOS's deployment target, otherwise, *just* the minimum deployment target". The wildcard doesn't include platforms that were explictly added to the statement, which can be visualized by how it's not possible to specify a platform multiple times.

```swift
if #available(iOS 12, *)
if #available(iOS 12, iOS 13, *) // Error: Version for 'iOS' already specified
```

For unavailability, this means that `#unavailable(*)` and `#unavailable(notWhatImCompiling X, *)` should return `false`. Since the minimum deployment target will always be present, the statement can never be true. This behavior also matches how a theoretical `!#available(*)` would behave if building expressions with `#available` was possible.

```swift
if #unavailable(*) {
  // Will never be executed
} else {
  // ...
}
```

The wildcard *only* represents platforms that were unspecified in the statement. This means that `#unavailable(iOS 13, *)` doesn't mean "iOS 13 *and* iOS's minimum deployment target", but "if iOS, iOS 13, otherwise the minimum deployment target"

As an interesting side effect, this means that having multiple unavailability checks in the same statement (`#unavailable(iOS 13, *), #unavailable(watchOS 3, *)` as opposed to `#unavailable(iOS 13, watchOS 3, *)`) would cause the statement to always be false. 

In these cases, since wildcard checks are eventually optimized to boolean literals, the compiler will already emit a warning indicating that the code will never be executed. Still, we can provide a more descriptive diagnostic that suggests using a single check that considers all platforms. 

```swift
if #unavailable(iOS 13, *), #unavailable(watchOS 3, *) {
  // ... 
  // Warning: code will never be executed
  // Error: unavailability checks are canceling each other, use a single check that treats all platforms 
  // fix-it: #unavailable(iOS 13, watchOS 3, *)
}
```

### Result builders

As `#unavailable` behaves exactly like `#available`, [`ViewBuilder`](https://developer.apple.com/documentation/swiftui/viewbuilder) does not need to be modified to support it. Using `#unavailable` on a builder will simply instead trigger [`buildLimitedAvailability(_:)`](0289-result-builders.md#availability) in the `else` block.

## Source compatibility and ABI

This change is purely additive.

## Alternatives considered

### `!#available(...)` and `#available(...) == false`

While allowing the original condition to be reversed seems to be the obvious choice, supporting it in practice would require hardcoding all of this behavior as `#available` cannot be used as an expression. The author would rather not add tech debt to the compiler. On the other hand, given that it's fair to consider that this is a developer's first guess when attempting to do unavailability, the compiler will provide fix-its for each of these spellings.

Refactoring `#available` to be usable as an expression would likely require refactoring the entire symbol availability system and has an extensive amount of implications and edge cases. The work to support it would be considerably beyond what is proposed here.

Supporting it by hardcoding this behavior is possible though, and could be implemented if the core team is willing and has a plan to eliminate the resulting tech debt in the future.
