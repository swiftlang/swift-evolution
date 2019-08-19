# didSet Semantics

* Proposal: [SE-NNNN](NNNN-didset-semantics.md)
* Author: [Suyash Srijan](https://www.github.com/theblixguy) 
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#26632](https://github.com/apple/swift/pull/26632) 

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
  
  private var value: Value?
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

This also resolves some pending bugs such as [SR-11297](https://bugs.swift.org/browse/SR-11297), [SR-11280](https://bugs.swift.org/browse/SR-11280) and [SR-5982](https://bugs.swift.org/browse/SR-5982).

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

## Effect on ABI stability

This does not affect the ABI as observers are not a part of it.

## Effect on API resilience

This does not affect API resilience - library authors can freely switch between a `didSet` which does not refer to the `oldValue` in its body and one which does and freely add or remove `didSet` from the property.

## Alternatives considered

Leave the existing behavior as is.

## Future Directions

We can apply the same treatment to `willSet` i.e. not pass the `newValue` if it does not refer to it in its body, although it wouldn't provide any real benefit as not passing `newValue` to `willSet` does not avoid anything, where as not passing `oldValue` to `didSet` avoids loading it.

We can also deprecate the implicit `oldValue` and request users to explicitly provide `oldValue` in parenthesis (`didSet(oldValue) { ... }`) if they want to use it in the body of the observer. This will make the new behavior more obvious and self-documenting.
