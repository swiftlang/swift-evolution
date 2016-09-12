# Remove Partial Application of Non-Final Super Methods (Swift 2.2)

* Proposal: [SE-0013](0013-remove-partial-application-super.md)
* Author: [David Farler](https://github.com/bitjammer)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007316.html)


## Introduction

Prior to Swift 2.2, calls to superclass methods like `super.foo()` in
Native Swift classes were dispatched statically by recording a reference
to the function and calling it directly by its mangled name. In Swift
2.2, class methods invoked via `super` will use dynamic dispatch. That
is, the method will be looked up in the superclass's vtable at runtime.
However, if the method is marked with `final`, it will use the old
static dispatch, since no class will be able to override it.

The mechanisms that support currying require thunks to be emitted so
that the function can be called at various uncurrying levels. Currying
will be removed in Swift 3.0 so, rather than invest more engineering in
those mechanisms, I propose that we disallow partial application of
non-final methods through `super`, except where the `self` parameter is
implicitly captured.

[Swift Evolution Discussion Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/000947.html)

## Motivation

The motivation of this change is partially motivated by implementation
concerns. The machinery for curry thunk mechanism has a lot of
assumptions about what the ultimate function call will be: an apply of a
static `function_ref` or a dynamic dispatch through a `class_method`,
which originate in something like `doFoo(self.foo)` (note `self` instead
of `super`). Rather than risk regressions stemming from significant
replumbing, it would a good tradeoff to pull in this limited portion of
the currying removals in Swift 3.0.

## Detailed design

In terms of design and implementation, this is a trivial change. In
semantic analysis, perform the following check on call expressions: if
the call expression is based in super, the referenced function isn't
final, and the application does not fulfill all of the parameters, emit
an error diagnostic.

### Example Code

#### Illegal: Partial application of non-final method

```swift

func doFoo(f: () -> ()) {
  f()
}

class Base {
  func foo()() {}
}

class Derived : Base {
  override func foo()() {
    doFoo(super.foo()) // Illegal - doesn't apply the second time.
  }
}
```

#### OK: Partial application of final method

This is safe because the new dynamic super dispatch mechanisms don't
kick in for final methods - these fall back to the original static
function reference because no class can ever override the original
implementation.

```swift

func doFoo(f: () -> ()) {
  f()
}

class Base {
  final func foo()() {}
}

class Derived : Base {
  func bar() {
    doFoo(super.foo()) // OK - method is final.
  }
}
```

The implementation for this change is available on [apple/swift/remove-partial-super].

#### OK: Partial application with implicit self

Partial application of the implicit self parameter is still allowed with
this change. When you pass `super.foo` around, you have in fact
partially applied the method - you've captured the `self` argument
present in all Swift method calls. This is safe because no explicit
thunks need to be generated at SILGen - the `partial_apply` instruction
will create a closure without additional SIL code.

```swift

func doFoo(f: () -> ()) {
  f()
}

class Base {
  func foo() {}
}

class Derived : Base {
  func bar() {
    doFoo(super.foo) // OK - only partially applies self
  }
}
```

## Impact on existing code

Given that we've decided to remove currying outright, this would be a
small percentage of that usage. Generally, calls on `super` are for
delegation, where all arguments are often present.

## Alternatives considered

The only alternative is to make super method dispatch a citizen in the
thunk emission process, which requires deep changes to SILGen, symbol
mangling, and IRGen. Although this more comprehensive change would allow
us to adopt dynamic super dispatch with no source changes for those
writing in Swift, I believe the proposal is a reasonable tradeoff.

[apple/swift/remove-partial-super]: https://github.com/apple/swift/tree/remove-partial-super
