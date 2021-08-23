# `weak(guard)` capture specifier for closure capture lists

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#38718](https://github.com/apple/swift/pull/38718)

## Introduction

This proposal introduces a new `weak(guard)` capture specifier for closure capture lists. `weak(guard)` captures objects as a `weak` reference, but the closure body is only executed if the referenced object still exists. Within the closure body, objects captured with `weak(guard)` are available as non-optional values. When using `weak(guard) self`, implicit `self` is permitted within the closure body.

```swift
class ViewController {
    let button: Button

    func setup() {
        button.tapHandler = { [weak(guard) self, weak(guard) button] in
            if canBeDismissed(by: button) {
                dismiss()
            }
        }
    }
}
```

Swift-evolution thread: [`guard` capture specifier for closure capture lists](https://forums.swift.org/t/guard-capture-specifier-for-closure-capture-lists/50805)

## Motivation

In some classes of Swift programming, such as UI programming, closures are the predominant way to perform action handling and send event notifications between multiple objects. When passing closures between parent objects and their children, special care must be taken to avoid retain cycles.

For example, this sample code weakly captures `self` and `button` to prevent a retain cycle, and uses a `guard` to guarantee that the main portion of the closure body only executes if `self` and `button` still exist:

```swift
class ViewController {
    let button: Button

    func setup() {
        button.tapHandler = { [weak self, weak button] in
            guard let self = self, let button = button else { return }

            if self.canBeDismissed(by: button) {
                self.dismiss()
            }
        }
    }
}
```

This pattern (`weak` captures with a `guard`) is extremely common. In fact, it is one of the most common patterns associated with non-strong closure captures. There are several notable drawbacks to this pattern, however, which could be improved.

### `weak` is often preferred over `unowned`

Both `weak` captures and `unowned` captures can be used to prevent retain cycles, but there are many domains and applications where `weak` is preferable over `unowned`.

 - `unowned` references cause the application to crash if the closure executed after the captured object has been deallocated. Crashing on invalid access is _memory-safe_, but is [often considered undesirable](https://forums.swift.org/t/guard-capture-specifier-for-closure-capture-lists/50805/39) from the perspective of application stability.

 - Avoiding crashes with `unowned` requires non-local reasoning. It is often not possible to know whether or not the captured objects will still exist when the closure is called without reading all code that can potentially call the closure. 

For these reasons, `weak` captures are (in general) used significantly more often than `unowned` captures. Searching public Swift code on GitHub, for example, gives [325k examples](https://github.com/search?l=Swift&q=%22weak+self%22&type=Code) of `weak self` captures, compared to only [80k examples](https://github.com/search?l=Swift&o=desc&q=%22unowned+self%22&s=indexed&type=Code) of `unowned self` captures. That is, 80% of non-strong `self` captures use `weak`.

### `weak` captures don't support implicit `self`
 
As of [SE-0269](https://github.com/apple/swift-evolution/blob/main/proposals/0269-implicit-self-explicit-capture.md), strong and `unowned` captures of `self` enable implicit `self` within the body of escaping closures. This is not straightforward to support for `weak` closures in the general case, and was [intentionally excluded](https://github.com/apple/swift-evolution/blob/main/proposals/0269-implicit-self-explicit-capture.md#weak-captures-of-self) from SE-0269.

### `weak` captures are typically paired with a `guard`

In action handling and event notification closures, there is typically no work to perform if `self` (or other captured objects) no longer exist. Because of this, a large number of these closures simply `guard` that the weakly captured object still exists, and otherwise do nothing (or perform other control flow with equivalent semantics).

For example, in a [survey](https://forums.swift.org/t/guard-capture-specifier-for-closure-capture-lists/50805/69) of public Swift code, it was found that **90% or more** of surveyed `weak self` closures only execute if `self` still exists.

Closure syntax is lightweight, but the `guard` statement for a corresponding `weak` capture is relatively heavy. For example, in the example above the `guard` statement is more code (by symbol count) than the rest of the closure body combined. When used frequently, as the "default" pattern for `weak` captures, this can be become "noise" / "boilerplate" that hampers readability.

### The status quo encourages ignoring potential errors

As demonstrated above, the predominant "status quo" for preventing retain cycles in closures is to use `weak` captures with a `guard let value = value else { return }` (or other control flow construct with equivalent semantics). 

A [common criticism](https://forums.swift.org/t/guard-capture-specifier-for-closure-capture-lists/50805/55) of this pattern is that it ignores edge cases where the captured objects no longer exist. This can be safe, but can also be harmful if applied thoughtlessly. `unowned` captures, on the other hand, defend against this case by unconditionally halting execution (crashing, even in release / `-O` builds).

A middle-ground alternative would be to emit an [`assertionFailure`](https://developer.apple.com/documentation/swift/1539616-assertionfailure) if a weakly captured object no longer exist. This would halt execution in debug (`-Onone`) builds, alerting the author about the potential issue, without crashing in release (`-O`) builds. As a "default" pattern, this would be strictly safer than ignoring these cases completely. 

## Proposed solution

We should introduce a new `weak(guard)` capture specifier:

```swift
class ViewController {
    let button: Button

    func setup() {
        button.tapHandler = { [weak(guard) self, weak(guard) button] in
            if canBeDismissed(by: button) {
                dismiss()
            }
        }
    }
}
```

`weak(guard)` captures objects as a `weak` reference, but the closure body is only executed if the referenced object still exists. Within the closure body, objects captured with `weak(guard)` are available as non-optional values. 

When using `weak(guard) self`, implicit `self` is permitted within the closure body (following the precedent of [SE-0269](https://github.com/apple/swift-evolution/blob/main/proposals/0269-implicit-self-explicit-capture.md)).

If any objects captured with `weak(guard)` no longer exist, the program emits an `assertionFailure`. This halts execution in debug (`-Onone`) builds, and has no effect in release (`-O`) builds.

## Detailed design

`weak(guard)` captures are transformed into a `weak` capture with a corresponding `guard` statement. This guarantees that the closure body, as written, will only be executed if the captured object still exists.

For example, this code:

```swift
button.tapHandler = { [weak(guard) self, weak(guard) button] in
    // ...
}
```

is transformed to:

```swift
button.tapHandler = { [weak self, weak button] in
    guard let self = self else {
        assertionFailure("""
            Assertion failure: Weakly captured object 'self' no longer exists. 
            (In release (-O) builds, this assertion is not evaluated, and 
            program execution will continue uninterrupted.)
        """)
        
        return
    }

    guard let button = button else {
        assertionFailure("""
            Assertion failure: Weakly captured object 'button' no longer exists. 
            (In release (-O) builds, this assertion is not evaluated, and 
            program execution will continue uninterrupted.)
        """)

        return
    }

    // ...
}
```

`weak(guard)` captures are only permitted in closures that return `Void`. Attempting to use a `weak(guard)` capture in a closure that does not return `Void` will result in an error with the following fixit:

```swift
// 🛑 `weak(guard)` capture specifiers are only permitted in closures that return `Void`
// FIXIT: Change `weak(guard)` to `weak` and insert `guard let self = self else { <#handle case where 'self' is nil#> }`
var canBeDismissed: () -> Bool = { [weak(guard) self] in  
    return true
}
```

## Source compatibility

This proposal is purely additive, and has no effect on source compatibility.

## Effect on ABI stability

This proposal desugars into existing syntax, so has no effect on ABI stability.

## Effect on API resilience

After being parsed, `weak(guard)` captures are treated as `weak` closures. This proposal has no visible effects on the public API of closures. Changing a `weak` capture to a `weak(guard)` capture, and vice versa, is always permitted and has no effects on public API.

## Alternatives considered

### Alternative spellings

Many alternative spellings were discussed in the pitch thread. The original draft of this proposal used `[guard self]` rather than `[weak(guard) self]`. Other proposed spellings include `[guard weak self]`, `[assert self]`, `[weak(assert) self]`, `[assert weak self]`, `[if self]`, `[if let self]`, `[if let weak self]`, etc.

The `weak(guard)` spelling was chosen because:
 - it emphasizes that the capture creates a `weak` reference
 - it alludes to the `guard`-like semantics of this capture specifier (that the closure body will only execute if a condition is true) and is evocative of the pattern that it replaces
 - it follows the style precedent set by `unowned`'s `unowned(safe)` and `unowned(unsafe)` variants.

### Use a `guard` without an `assertionFailure`

In the original draft of this proposal, `weak(guard)` captures were transformed to a `weak` capture with a `guard let value = value else { return }` (e.g. without an `assertionFailure`). 

One obstacle with that approach is that it makes it more challenging to debug, or be notified of, cases where the closure is executed after captured variables are deallocated (since the closure body is not executed, and there is nowhere to put a breakpoint). An `assertionFailure` will halt execution in debug (`-Onone`) builds, which notify the author of the issue and allow them to debug it.

Including an `assertionFailure` is strictly safer than ignoring these cases completely. This makes it dramatically more likely that authors will discover cases where their expectations are potentially being violated, without causing crashes in release builds.

### Support closures that return a value

In this proposal, `weak(guard)` captures are only permitted in closures that return `Void`. To support `weak(guard)` closures for closures that return an actual value, we would have to pursue directions like:

 - provide a default value that is returned if the captured objects no longer exist (e.g. automatically return `nil` for closures that return an `Optional`).
 - provide a way to specify the return value in the capture list (like `[weak(guard) self else nil]`, as a strawman syntax).

These sorts of designs either promote hidden behaviors and implicit default initialization, or would require new syntax that is not meaningfully better than the status quo. 

In a [survey](https://forums.swift.org/t/guard-capture-specifier-for-closure-capture-lists/50805/69) of public Swift code, a substantial majority of closures using `weak self` returned `Void` -- so the proposed behavior of `weak(guard)` is useful in a substantial majority of real-world use cases of `weak` captures.

## Acknowledgments

Thanks to everyone who participated in the pitch process for this proposal! Special thanks to Nathan Lawrence, Jordan Rose, and Eric Horacek, whose valuable feedback was directly incorporated into the final semantics and naming of this feature.