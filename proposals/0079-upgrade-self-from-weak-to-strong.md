# Allow using optional binding to upgrade `self` from a weak to strong reference

* Proposal: [SE-0079](0079-upgrade-self-from-weak-to-strong.md)
* Author: [Evan Maloney](https://github.com/emaloney)
* Review Manager: TBD
* Status: **Deferred**

## Introduction

When working with escaping Swift closures, it is a common pattern to have the closure capture `self` weakly to avoid creating an object reference cycle.

For example, let’s say you have a view controller that displays the result of a network operation. When the view controller is placed onscreen, it starts the operation and provides a closure to be executed upon completion.

The fact that a network operation may be in-flight should not prevent user from navigating away from that view controller. Similarly, we don’t want a pending network operation to prevent our view controller from being deallocated after it goes offscreen. In other words, we only care about the network operation while the view controller is alive; once the view controller has been deallocated, we can safely ignore the result of any network request it initiated.

To achieve this, the networking code might look something like:

```swift
networkRequest.fetchData() { [weak self] result in
	guard let strongSelf = self else { return }

	switch result {
	case .Succeeded(let data):
		strongSelf.processData(data)
	
	case .Failed(let err):
		strongSelf.handleError(err)
	}
}
```

When it comes time to execute this closure, the `guard` statement effectively asks the question, “Is the view controller represented by `self` still alive?” If the answer is no, the guard forces a return and the rest of the closure does not execute.

If `self` *is* still alive, then the weakly-captured `self` will be non-`nil` and it will be converted into a strong reference held by `strongSelf` for the duration of the closure’s execution.

When the closure finishes, `strongSelf` goes away, once again making the view controller represented by `self` eligible for deallocation if no other references are held.

## The Problem

The only available mechanism for upgrading a weak `self` to a strong reference requires the creation of a `self`-like variable with an arbitrary name—in the example above, `strongSelf`.

Because there is no compiler-level mechanism for enforcing a consistent name across an entire codebase, in some instances `strongSelf` may be `ss` or it may be `s` or it may be a random sequence of characters that captures the developer’s mood of the moment.

This lack of consistency adds noise to the codebase, and makes code harder to reason about, especially in cases where the strong reference is held by a variable with a name more cryptic than `strongSelf`.

Being able to upgrade `self` from a weak reference to a strong reference while retaining the name `self` would be ideal, and it would be consistent with the existing Swift convention of optional binding that reuses the name of the optional variable, eg.:

```swift
// foo is an optional here
if let foo = foo {
    // foo is non-optional here;
    // the optional foo is masked within this scope
}
// foo is once again an optional here
```

## Proposed Solution

The proposed solution entails allowing `self` to be upgraded from a weak reference to a strong reference using optional binding.

In any scope where `self` is a weak reference, the compiler will accept an `if` or `guard` statement containing an optional binding that upgrades `self` to a strong reference.

This would allow `self` to keep its meaningful name instead of being renamed to something arbitrary.

With this feature, the code above could be rewritten as:

```swift
networkRequest.fetchData() { [weak self] result in
	guard let self = self else { return }

	switch result {
	case .Succeeded(let data):
		self.processData(data)
	
	case .Failed(let err):
		self.handleError(err)
	}
}
```

The following would also be legal:

```swift
networkRequest.fetchData() { [weak self] result in
	if let self = self {
		switch result {
		case .Succeeded(let data):
			self.processData(data)
	
		case .Failed(let err):
			self.handleError(err)
		}
	}
}
```

## Behavior

Regardless of which notation is used for this feature, the behavior is the same:

- The strong `self` can only be assigned from the optional `self` resulting from a weak capture in a closure.

- Once bound, the strong `self` follows the same scoping rules as any other optionally-bound variable.

- While the strong `self` is in scope, it masks the weak `self` variable. If the strong reference to `self` goes out of scope before the weak `self` reference does, the weak `self` will once again be visible to code.

## Restrictions

To ensure safety, the compiler will enforce certain restrictions on the use of this feature:

- Attempting to use this feature in a context where `self` is not a weak reference will cause a compiler error. 

- Binding of `self` may only be used with `let`; attempting to bind `self` to a `var` is an error. (Because this feature only works with object references and not value types, this restriction does not affect the mutability of `self`.)

## Impact on Existing Code

None, since this does not affect any existing constructs. Implementation of this proposal will not result in any code breakage.

## Alternatives Considered

### Status quo

The primary alternative is to do nothing, requiring developers to add boilerplate guard code and handle upgrading the weak-to-strong references manually.

As stated above, this leads to needless boilerplate that can easily be factored out by the compiler. Also, the use of a `self`-like variable with an arbitrary name makes it more difficult to exhaustively find such uses in large projects.

Finally, the need to declare and use alternate names to capture values that already have existing names adds visual clutter to code and serves to obscure the code’s original intent, making it harder to reason about.

### Relying on a compiler bug

There is a bug in current versions of the Swift compiler that allow `self` to be assigned when the word is surrounded by backticks.

This bug causes the following code to compile and work:

```swift
guard let `self` = self else {
    return
}
```

Apple’s Chris Lattner has stated that “[this is a compiler bug](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007425.html)”.

Therefore, we should not rely on this “feature” to work in the future, because the bug will (presumably) be fixed eventually.

### Adding a new `guard` capture type

An alternate to this proposal involves adding [a new capture type, called `guard`](https://gist.github.com/emaloney/d34ac9b134ece7c60440), which would automatically handle upgrading `self` (and other references) from weak to strong.

Although the alternate proposal received a favorable response from the Swift Evolution mailing list, the community seemed split between the approach outlined in that proposal, and the one outlined here.

## Citations

Variations on this proposal were discussed earlier in the following [swift-evolution](https://lists.swift.org/mailman/listinfo/swift-evolution) threads:

- [Wanted: syntactic sugar for [weak self] callbacks](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160201/008713.html)
- [Allowing `guard let self = self else { … }` for weakly captured self in a closure.](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160201/009023.html)
- [[Draft Proposal] A simplified notation for avoiding the weak/strong dance with closure capture lists](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160201/009241.html)
- [[Proposal Update 1] A simplified notation for avoiding the weak/strong dance with closure capture lists](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160208/009972.html)
- [[Proposal] Allow upgrading weak self to strong self by assignment](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010691.html)
- [[Proposal] Allow using optional binding to upgrade self from a weak to strong reference](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010759.html)
- [[Last Call] Allow using optional binding to upgrade self from a weak to strong reference](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/010904.html)
