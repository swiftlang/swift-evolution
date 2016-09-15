# Limiting `inout` capture to `@noescape` contexts

* Proposal: [SE-0035](0035-limit-inout-capture.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-February/000046.html)
* Bug: [SR-807](https://bugs.swift.org/browse/SR-807)


## Introduction

Swift's behavior when closures capture `inout` parameters and escape their enclosing context is a common source of confusion. We should disallow implicit capture of `inout` parameters
except in `@noescape` closures.

Swift-evolution thread: [only allow capture of inout parameters in @noescape closures](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160125/008074.html)

[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010465.html)

## Motivation

Before we had `@noescape`, we still wanted `inout` parameters and `mutating` methods
to be usable in closures, without compromising the strong guarantee that an `inout`
parameter can only locally mutate its parameter without callers having to worry about
unexpected aliasing or lifetime extension. Since Swift uses closures pervasively for standard
library collection operations, and even for assertions and operators like `&&` and
`||` via its `@autoclosure` feature, it would be extremely limiting if `inout`
parameters could not be captured at all. Dave Abrahams designed our current capture
semantics as a compromise: an `inout` parameter is captured as a **shadow copy** that is
written back to the argument when the callee returns. This allows `inout` parameters
to be captured and mutated with the expected semantics when the closure is called while
the inout parameter is active:

```swift
func captureAndCall(inout x: Int) {
  let closure = { x += 1 }
  closure()
}
var x = 22
captureAndCall(&x)
print(x) // => 23
```

But this leads to unintuitive results when the closure escapes, since the *shadow copy* is
persisted independently of the original argument:

```swift
func captureAndEscape(inout x: Int) -> () -> Void {
  let closure = { x += 1 }
  return closure
}

var x = 22
let closure = captureAndEscape(&x)
print(x) // => 22
closure()
print("still \(x)") // => still 22
```

This change has been a persistent source of confusion and bug reports, and was recently
called out in David Ungar's recent post to the IBM Swift Blog, ["Seven Swift Snares & How to Avoid Them"](https://developer.ibm.com/swift/2016/01/27/seven-swift-snares-how-to-avoid-them/),
one in a long line of complaints on the topic.

## Proposed solution

I propose we make it so that implicitly capturing an `inout` parameter into an escapable
closure is an error. We added the explicit `@noescape` annotation in Swift 1.2, and have since
adopted it throughout the standard library where appropriate, so the compromise has outlived
its usefulness and become a source of confusion.

## Detailed design

Capturing an `inout` parameter, including `self` in a `mutating` method, becomes an error
in an escapable closure literal, unless the capture is made explicit (and thereby immutable):

```swift
func escape(f: () -> ()) {}
func noEscape(@noescape f: () -> ()) {}

func example(inout x: Int) {
  escape { _ = x } // error: closure cannot implicitly capture an inout parameter unless @noescape
  noEscape { _ = x } // OK, closure is @noescape
  escape {[x] in _ = x } // OK, immutable capture
}

struct Foo {
  mutating func example() {
    escape { _ = self } // error: closure cannot implicitly capture a mutating self parameter
    noEscape { _ = self } // OK
  }
}
```

For nested function declarations, we defer formation of a closure until a reference to
the unapplied function is used as a value. If a nested function references `inout` parameters
from its enclosing scope, we disallow references to the nested function that would
form an escaping closure:

```swift
func exampleWithNested(inout x: Int) {
  func nested() {
    _ = x
  }
  escape(nested) // error: nested function that references an inout cannot be escaped
  noEscape(nested) // OK
}
```

As an implementation detail, this eliminates the need for a shadow copy to be emitted for
inout parameters in case they are referenced by closures. For code that is still accepted
after this change, this should not have an observable effect, since a guaranteed optimization
pass always removes the shadow copy when it is known not to escape.

## Impact on existing code

This will break code that relies on the current `inout` capture semantics. Some particular
legitimate cases that may be affected:

- A closure captures the parameter after its local mutations, and never mutates it further
  or expects to observe mutations from elsewhere. These use cases can explicitly capture
  the `inout` parameter immutably using a capture list, which is both more explicit and
  safer.
- The `inout` parameter is captured by escapable closures that dynamically never execute
  outside the originating scope, for instance, by referencing the parameter in a `lazy`
  sequence adapter that is applied in the immediate scope, or by forking off one or more
  `dispatch_async` jobs that access different parts of the parameter but which are
  synced with the originating scope before it exits. For these use cases, the shadow copy
  can be made explicit:
  
    ```swift
	func foo(q: dispatch_queue_t, inout x: Int) {
	  var shadowX = x; defer { x = shadowX }
	  
	  // Operate on shadowX asynchronously instead of the original x
	  dispatch_async(q) { use(&shadowX) }
	  doOtherStuff()
	  dispatch_sync(q) {}
	}    
    ```
    
For migration, the compiler can offer one of the above fixits, checking the use of the captured
`inout` for mutations after the capture to decide whether an immutable capture or explicit
shadow copy is more appropriate. (Or naively, the fixit can just offer the shadow copy fixit.)

This also increases pressure on libraries to make more use of `@noescape` where possible, as
proposed in [SE-0012](0012-add-noescape-to-public-library-api.md).

## Alternatives considered

A possible extension of this proposal is to introduce a new capture kind to ask for shadow copy
capture:

```swift
func foo(inout x: Int) {
  {[shadowcopy x] in use(&x) } // strawman syntax
}
```

In discussion, we deemed this rare enough not to be worth the added complexity. An explicit
copy using a new `var` declaration is much clearer and doesn't require new language support.
