# Allow class convenience initializers to reassign `self`

* Proposal: [SE-ZZZZ](ZZZZ-convenience-init-self.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#19311](https://github.com/apple/swift/pull/19311)

## Introduction

Allow class convenience initializers to produce their result by assigning
`self` to an existing class instance as an alternative to invoking another
initializer by `self.init`.

Swift-evolution thread: [Allow `self = x` in class convenience initializers](https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924)

## Motivation

It is sometimes useful for an initializer to return an existing
instance of a type instead of creating an entirely new one. For value types,
there is no formal difference between building an equivalent value
piece-by-piece or by copying, and it is already possible to initialize by
assignment:

```
struct X {
  var x, y: Int
  static var defaultValue = X(x: 17, y: 38)

  init() {
    // effectively equivalent to self.init(x: defaultValue.x, y: defaultValue.y)
    // or self.x = defaultValue.x; self.y = defaultValue.y
    self = X.defaultValue
  }
}
```

Initializers defined in protocol extensions can similarly assign to `self`
to produce their result, and in fact, they *must* either assign to `self` or
invoke another initializer via `self.init` (which is equivalent to
`self = type(of: self).init`), since the protocol extension has no more
specific knowledge of a type's layout with which to perform finer-grained
initialization.

For classes, unlike value types, identity is significant, but convenience
initializers are otherwise very similar in their limitations to protocol
extension initializers. Because a convenience initializer is
required to delegate to another initializer in order to produce a value, and
the delegated-to initializer is responsible for setting the initial state of
the entire object, a convenience initializer is unable to reference `self`
in other ways before it has delegated to another `self.init`, just like
a protocol extension initializer. There are many reasons a class initializer
may want to reassign `self`, such as to return a specific singleton instance:

```
final class FileManager {
  private static let theFileManager = FileManager()

  convenience init(shared: ()) {
    self = FileManager.theFileManager
  }
}
```

or to cache instances:

```
open class Number {
  private static var cachedZeros: [Number.Type: Number] = [:]

  open required init(createZero: ()) { fatalError("abstract") }

  public convenience init(zero: ()) {
    if let cachedInstance = Number.cachedZeros[type(of: self)] {
      self = cachedInstance as! Self
    } else {
      self.init(createZero: ())
      Number.cachedZeros[type(of: self)] = self
    }
  }
}
```

Many Swift codebases, including Swift's own standard library, currently
resort to hacks to get this behavior, sticking otherwise-unnecessary protocol
extensions on classes, which is inefficient and awkward.

## Proposed solution

We should allow self to be assigned to inside convenience initializers.

## Detailed design

The definite initialization rules for convenience initializers can be relaxed
to be the same as those for protocol extension initializers or delegating
value type initializers: on every successful code path through
the initializer, a `self.init` call or assignment to `self` must have happened
at least once. In addition to the obvious consequence of allowing `self`
assignment within convenience initializers, this also loosens the rules
around convenience initializers in some other ways:

- `self.init(...)` becomes effectively equivalent to
  `self = type(of: self).init(...)` (or more succinctly, `self = .init(...)`),
  as in value type and protocol extension initializers.
- `self` can be reassigned, or `self.init` invoked again, after the initial
  assignment. Although this may seem useless, this allows convenience
  initializers to recover after `catch`-ing an error from a failed `self.init`
  delegation by attempting a different delegation or assignment instead:

    ```
    class X {
      init(first: ()) throws { ... }
      init(second: ()) { ... }

      convenience init() {
        do {
          try self.init(first: ())
        } catch {
          self.init(second: ())
        }
      }
    }
    ```

    Currently, this is considered an error, because the failed delegation is
    seen as irrecoverably destroying the instance under construction. Although
    this behavior makes sense for designated initializers, it is an unnecessary
    restriction for convenience initializers under this new model.

This proposal does not change the existing inheritance rules for convenience
initializers; convenience initializers are still inherited by a subclass that
overrides all of its base class's designated initializers. Because convenience
initializers can be inherited, the `self` variable has to have dynamic `Self`
type in a non-final class initializer, so it can only be assigned values that
are also of `Self` type.

## Source compatibility

Swift 4 incorrectly and unsoundly treats `self` in non-final class
convenience initializers as having the concrete type rather than dynamic
`Self` type. This unsoundness was only fixed in Swift 5, because it causes
source compatibility breakage in Swift 4, and would be extremely easy to misuse
with the added ability to reassign `self`. Therefore, this feature is proposed
only to be enabled in Swift 5.

## Effect on ABI stability

There is no ABI impact. Convenience initializers can already delegate to
protocol extension initializers, which in turn can reassign `self` to an
arbitrary class instance, so allowing class convenience initializers to also
reassign `self` does not weaken guarantees any further than they already are;
it already cannot be assumed that a convenience initializer returns a specific
instance of a class, always returns a new instance, or always returns an
instance with the exact dynamic type for which the initializer was invoked.

## Effect on API resilience

This feature adds the ability for convenience initializers to resiliently
evolve between "true" initialization behavior (that is,
delegating to a designated initializer to produce a fresh instance) and
"factory-like" behavior, producing cached or singleton instances. (Note however
that this is not exactly the same feature as factory initializers; see
"Alternatives considered" below for further discussion.)

## Alternatives considered

This functionality is similar, but not quite the same as, the sometimes-requested
"factory initializer" feature. A factory is typically not expected to be
inherited, and wants to use a specific base class type instead of `Self` as its
return type:

```
class Root {
  // Returns some subclass of Root, not necessarily Self
  static func get(parameters: [String: Any]) -> Root {
  }
}
```

Because convenience initializers do not change their inheritance behavior under
this proposal, they are not a perfect fit for this role. With the generalization
of `Self` from [SE-68](https://github.com/apple/swift-evolution/blob/master/proposals/0068-universal-self.md),
one could force-cast to `Self` in a convenience init, making it a dynamic
precondition that it only be called on an appropriate base class for factory
purposes.
