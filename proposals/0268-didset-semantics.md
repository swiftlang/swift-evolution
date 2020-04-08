# Refine `didSet` Semantics

* Proposal: [SE-0268](0268-didset-semantics.md)
* Author: [Suyash Srijan](https://github.com/theblixguy)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.3)**
* Implementation: [apple/swift#26632](https://github.com/apple/swift/pull/26632)
* Bug: [SR-5982](https://bugs.swift.org/browse/SR-5982)

## Introduction

Introduce two changes to `didSet` semantics - 

1. If a `didSet` observer does not reference the `oldValue` in its body, then the call to fetch the `oldValue` will be skipped. We refer to this as a "simple" didSet.
2. If we have a "simple" `didSet` and no `willSet`, then we could allow modifications to happen in-place.

Swift-evolution thread: [didSet Semantics](https://forums.swift.org/t/pitch-didset-semantics/27858)

## Motivation

Currently, Swift always calls the property's getter to get the `oldValue` if we have a `didSet` observer, even if the observer does not refer to the `oldValue` in its body. For example:

```swift
class Foo {
  var bar: Int {
    didSet { print("didSet called") }
  }

  init(bar: Int) { self.bar = bar }
}

let foo = Foo(bar: 0)
// This calls the getter on 'bar' to get 
// the 'oldValue', even though we never 
// refer to the oldValue inside bar's 'didSet'
foo.bar = 1
```

This might look harmless, but it is doing redundant work (by allocating storage and loading a value which isn't used). It could also be expensive if the getter performs some non-trivial task and/or returns a large value.

For example:

```swift
struct Container {
  var items: [Int] = .init(repeating: 1, count: 100) {
    didSet {
      // Do some stuff, but don't access oldValue
    }
  }
  
  mutating func update() {
    for index in 0..<items.count {
      items[index] = index + 1
    }
  }
}

var container = Container()
container.update()
```

This will create 100 copies of the array to provide the `oldValue`, even though they're not used at all.

It also prevents us from writing certain features. For example, a `@Delayed` property wrapper may be implemented like this:

```swift
@propertyWrapper
struct Delayed<Value> {
  var wrappedValue: Value {
    get {
      guard let value = value else {
        preconditionFailure("Property \(String(describing: self)) has not been set yet")
      }
      return value
    }

    set {
      guard value == nil else {
        preconditionFailure("Property \(String(describing: self)) has already been set")
      }
      value = newValue
    }
  }
  
  var value: Value?
}

class Foo {
  @Delayed var bar: Int {
    didSet { print("didSet called") }
  }
}

let foo = Foo()
foo.bar = 1
```

However, this code will currently crash when we set `bar`'s value to be `1`. This is because Swift will fetch the `oldValue`, which is `nil` initially and thus will trigger the precondition in the getter.

## Proposed Solution

The property's getter is no longer called if we do not refer to the `oldValue` inside the body of the `didSet`.

```swift
class Foo {
  var bar = 0 {
    didSet { print("didSet called") }
  }

  var baz = 0 {
    didSet { print(oldValue) }
  }
}

let foo = Foo()
// This will not call the getter to fetch the oldValue
foo.bar = 1
// This will call the getter to fetch the oldValue
foo.baz = 2
```

This applies to a `didSet` on an overridden property as well - the call to the superclass getter will be skipped if the `oldValue` is not referenced in the body of the overridden property's `didSet`.

This also resolves some pending bugs such as [SR-11297](https://bugs.swift.org/browse/SR-11297) and [SR-11280](https://bugs.swift.org/browse/SR-11280).

As a bonus, if the property has a "simple" `didSet` and no `willSet`, then we could allow for modifications to happen in-place. For example:

```swift
// This is how we currently synthesize the _modify coroutine
_modify {
  var newValue = underlyingStorage
  yield &newValue
  // Call the setter, which then calls
  // willSet (if present) and didSet
  observedStorage = newValue
}

// This is how we're going to synthesize it instead
_modify {
  // Since we don't have a willSet and
  // we have a "simple" didSet, we can
  // yield the storage directly and
  // call didSet
  yield &underlyingStorage
  didSet()
}
```

This will provide a nice performance boost in some cases (for example, in the earlier array copying example).

## Source compatibility

This does not break source compatibility, _unless_ someone is explicitly relying on the current buggy behavior (i.e. the property's getter being called even if the `oldValue` isn't referenced). However, I think the possibility of that is very small.

It would still be possible to preserve the old behavior by either:

1. Explicitly providing the `oldValue` argument to `didSet`: 
```swift
didSet(oldValue) {
  // The getter is called to fetch
  // the oldValue, even if it's not
  // used in this body.
}
```
2. Forcing the getter to be called by simply ignoring its value in the body of the `didSet`: 
```swift
didSet {
  // Calls the getter, but the value
  // is ignored.
  _ = oldValue
}
```

## Effect on ABI stability

This does not affect the ABI as observers are not a part of it.

## Effect on API resilience

This does not affect API resilience - library authors can freely switch between a `didSet` which does not refer to the `oldValue` in its body and one which does and freely add or remove `didSet` from the property.

## Alternatives considered

- Explicitly require an `oldValue` parameter to use it, such as `didSet(oldValue) { ... }`, otherwise it is an error to use `oldValue` in the `didSet` body. This will be a big source breaking change. It will also cause a regression in usability and create an inconsistency with other accessors, such as `willSet` or `set`, which can be declared with or without an explicit parameter. The source compatibility problem can be mitigated by deprecating the use of implicit `oldValue` and then making it an error in the next language version, however the usability regression would remain.
- Introduce a new `didSet()` syntax that will suppress the read of the `oldValue` (and it will be an error to use `oldValue` in the `didSet` body). This will prevent any breakage since it's an additive change, but will reduce the positive performance gain (of not calling the getter when `oldValue` is not used) to zero unless people opt-in to the new syntax. Similar to the previous solution, it will create an inconsistency in the language, since it will be the only accessor that can be declared with an empty parameter list and will become yet another thing to explain to a newcomer.
- Leave the existing behavior as is.

## Future Directions

We can apply the same treatment to `willSet` i.e. not pass the `newValue` if it does not refer to it in its body, although it wouldn't provide any real benefit as not passing `newValue` to `willSet` does not avoid anything, where as not passing `oldValue` to `didSet` avoids loading it.

We can also deprecate the implicit `oldValue` and request users to explicitly provide `oldValue` in parenthesis (`didSet(oldValue) { ... }`) if they want to use it in the body of the observer. This will make the new behavior more obvious and self-documenting.
