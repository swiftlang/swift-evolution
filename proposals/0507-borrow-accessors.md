# Borrow and Mutate Accessors

* Proposal: [SE-0507](0507-borrow-accessors.md)
* Authors: [Meghana Gupta](https://github.com/meg-gupta), [Tim Kientzle](https://github.com/tbkka)
* Review Manager: [Doug Gregor](https://github.com/DougGregor/)
* Status: **Active review (January 26...February 9, 2026)**
* Vision: [[Prospective Vision] Accessors](https://forums.swift.org/t/prospective-vision-accessors/76707)
* Implementation: On `main` gated behind `-enable-experimental-feature BorrowAndMutateAccessors`
* Review: ([review](https://forums.swift.org/t/se-0507-borrow-and-mutate-accessors/84376))([pitch](https://forums.swift.org/t/pitch-borrowing-accessors/83933))

## Introduction

Borrowing accessors — introduced with the new keywords `borrow` and `mutate` — allow implementing computed properties and subscripts using *borrowing semantics*.  These augment the existing `get`, `set`, `yielding borrow`, and `yielding mutate` accessors to complete the design described in the “Prospective Vision for Accessors”:
https://forums.swift.org/t/prospective-vision-accessors/76707

To briefly summarize the discussion in that document, borrowing accessors have advantages over other accessor varieties in these circumstances:

* Unlike `get` accessors, borrowing accessors can expose a stored value without copying it
* Unlike `yielding borrow` and `yielding mutate` accessors, borrowing accessors do not require the overhead of a coroutine, making them more performant when they cannot be fully inlined.

Note that borrowing accessors do not replace all uses of the existing accessor variants.  In particular, `get`, `yielding mutate`, and `yielding borrow` can all provide access to constructed temporary values.  This makes `yielding mutate` and `yielding borrow` the most flexible options for general-purpose protocols whose conformers may need to expose temporary values.  In contrast, borrowing accessors can only expose values whose storage is guaranteed to be valid until the next mutation of the containing value.

## Motivation

The existing accessor variations have limitations that make them unsuitable for certain uses.

A `get` accessor must either copy an existing value or construct a new value to return to the client. This makes it unsuitable when you have stored data that is expensive or impossible to copy.  In particular, collections that store non-copyable values cannot use `get` for their subscript operations.

```swift
struct NC: ~Copyable { ... }
struct ContainerOfNoncopyable {
    private var _element: NC
    var element: Element {
        return _element // 🛑 ERROR: Cannot copy `_element`
    }
}
```

The `yielding mutate` and `yielding borrow` accessors satisfy a different need.  By exposing the access as a coroutine, they allow the provider to run code both before the value is exposed and after the client is done using the value.  This supports APIs such as the `Dictionary` subscript operation which constructs a new value for the duration of the access and destroys it when the access is complete.  Yielding accessors are also used to implement resilient access to class properties so that the provider can execute runtime exclusivity checks both before and after the access.

But the coroutines used by yielding accessors have drawbacks:  They can add significant overhead to allocate working space for the coroutine and to make multiple function calls into the coroutine.  They also limit the access scope.  The coroutine and all dependent accesses must complete before the end of the calling function:

```swift
struct Element: ~Copyable {
  var span: Span<...> { ... }
}

struct Wrapper: ~Copyable {
    private var _element: Element
    var element: Element {
        yielding borrow { // ❗️Note: Using `yielding borrow` accessor
            yield _element
        }
    }
}

func getSpan(wrapper: borrowing Wrapper) -> Span<...> {
    // Because we're reading `element` from a yielding accessor,
    // its access must finish before `getSpan` returns.
    // But `span` cannot outlive `element`, so ...

    // 🛑 ERROR: lifetime-dependent value escapes its scope
    return wrapper.element.span
}
```

>For more information about `yielding mutate`/`yielding borrow`, see: 
https://github.com/swiftlang/swift-evolution/blob/main/proposals/0474-yielding-accessors.md

## Proposed solution

Borrowing accessors are defined similarly to any other accessor, using the context-sensitive `borrow` and `mutate` keywords.  They use the `return` keyword to indicate the value being exposed.  The mutating version uses `&` to further indicate that the value is being exposed for potential mutation:

```swift
struct RigidWrapper<Element: ~Copyable>: ~Copyable {
    var _element: Element
    var element: Element {
        borrow {
            return _element
        }
        mutate {
            return &_element
        }
    }
}
```

Note:  We’ve included an explicit `return` keyword in the above examples to clarify the distinction with `yielding borrow` and `yielding mutate` which use a `yield` keyword.
As with other return values in Swift, the `return` keyword is optional when the body is a single expression.

## Detailed design

The above example shows how `borrow` and `mutate` accessors can be defined.  Note that the value being returned must be a stored value that will outlive the execution of the accessor.  It is illegal to return a local or temporary value:

```swift
struct InvalidExamples {
    var _array : [Int]
    
    var local: [Int] {
        borrow {
            let foo = [1, 2, 3]
            // 🛑 ERROR: Cannot return local value from borrow accessor
            return foo
        }
    }
    
    var temporary: [Int]? {
        borrow {
            // This would require creating a temporary local
            // optional array from `_array`.
            // 🛑 ERROR: Cannot return temporary value from borrow accessor
            return _array
        }
    }
}
```

#### Reading from properties that use `borrow`

Clients read a value via a `borrow` accessor using the same code they might use for a property implemented with `get`.  However, when a property is implemented with `borrow`, reading the value does not copy.  To preserve memory consistency, Swift’s exclusivity rules prevent the provider from being mutated while the borrow is active:

```swift
var owner = Wrapper(value)

// "borrow" the value to give to a function
// without copying...
doSomething(with: owner.element)

func doSomething(with value: borrowing Element) {
    // `value` is borrowed, so this invokes
    // the method "in-place"
    value.someMethod() 

    // Exclusivity prevents the owner from being
    // mutated while `value` is alive:
    owner.mutatingMethod() // 🛑 ERROR
}
```

#### Modifying properties that use  `mutate` 

Using a property implemented with `mutate` is similar.  It gives you read/write access for the duration of the borrow:

```swift
var owner = Wrapper(value)

// Mutating/inout access will invoke the `mutate` accessor
doSomething(with: &owner.element)

func doSomeMutation(with value: inout Element) {
    // So this invokes a method on the value "in-place"
    // Because you borrowed for mutation, this can be
    // a mutating method.
    value.someMutatingMethod()

    // Accessing the owner is an exclusivity violation
    owner.anyMethod() // 🛑 ERROR
}
```

#### Compatibility with other accessors

If you provide a `mutate` accessor:

* You must also provide a `borrow` accessor.
* You cannot have a `yielding mutate` or `yielding borrow`

These follow from two considerations:
First, Swift generally disallows write-only properties.
For example, Swift does not allow a property to only include a `set` accessor.
Secondly, we want to ensure compatible access scopes for read and write operations.
This not only ensures consistent behavior to clients of the property,
it also potentially allows the compiler to optimize a mix of read and write operations with a single unified `mutate` access.

If you provide a `borrow` accessor:

* You cannot also define a `get` or `yielding borrow`

This point is partly motivated by the same considerations as above.
In addition, we prohibit multiple read accessors (such as `borrow` and `get`) or
multiple write accessors (such as `mutate` and `yielding mutate`) because it
creates confusion in the caller as to which one will ultimately be used.[^2]

[^2]: In many cases, the compiler will synthesize multiple read or multiple write accessors in order to preserve ABI guarantees over time.  In every such case, the ABI considerations dictate which accessors will actually get used in a particular situation.

#### Ownership variations

By default, a `borrow` accessor is considered to not mutate the containing
value,
and a `mutate` accessor is assumed to act as a mutation of the
containing value.

This can be explicitly overridden by using a `mutating` or `nonmutating` modifier,
similarly to `mutating get` or `nonmutating set`.
In these combinations, the `mutating` or `nonmutating` prefix indicates
whether the operation is considered to mutate the containing value.

For example, a `mutating borrow` indicates that even though the
caller can only use this to read the property,
there can be side-effects that alter the containing value in other ways.
As a result, the property can only be accessed in a context
that allows mutation:
```swift
struct S1 {
  private var cachedValue: Foo
  var foo : Foo {
    mutating borrow {
      if !cachedValue.available {
        // Update `cachedValue`
        // Compiler allows such update
        // because this is `mutating`
      }
      return cachedValue
    }
  }
}

let s1: S1 // Note: Immutable value
s1.foo // 🛑 Cannot use mutating accessor on immutable value
```

Similarly, a `nonmutating mutate` would provide mutable borrow access to some value,
but a mutation of that value is _not_ a mutation of the parent value.
For example, this might be true if the accessor is providing access to a value
that is stored outside of the parent value:
```swift
struct Outer {
  var inner: InnerType {
    borrow {
      return some_value_stored_elsewhere
    }
    nonmutating mutate {
      return &some_value_stored_elsewhere
    }
  }
}
```
In this example, `inner` can be mutated, but such mutation is not considered to be a mutation of `Outer` for purposes of exclusivity and ownership diagnostics.

#### `borrow` and `mutate` as protocol requirements

Borrowing accessors can also appear as protocol requirements

```swift
protocol BorrowingAccess {
  associatedtype Element
  var element: Element { borrow mutate }
}
```

Requiring specific accessors in a protocol has two effects:

* It controls how clients can access properties through the protocol.  This includes access to properties on an existential or on a protocol-constrained generic argument.
* It requires these accessors to be present on any conforming type, either by being explicitly implemented, or by having the compiler synthesize implementations that call into whatever accessor was implemented.

If the implementation provides a stored property, the compiler can synthesize both `borrow` and `mutate` accessors to satisfy a protocol requirement.

If the implementation provides a `borrow` accessor, the compiler will be able to synthesize either a `yielding borrow` accessor (by yielding the borrowed reference) or a `get` accessor (only for copyable values).

If the implementation provides a `mutate` accessor, the compiler can synthesize either a `set` or `yielding mutate` accessor to satisfy a protocol requirement.

If the protocol requires a `borrow` accessor, the conforming type must provide a `borrow` accessor.

If the protocol requires a `mutate` accessor, the conforming type must provide both a `mutate` accessor and a `borrow` accessor.

No combinations other than those specified above are supported.

#### Cannot use for properties of classes or actors

Classes require runtime exclusivity checks to run both before and after each property access.  Since borrowing accessors do not provide a way for the provider to run code after the access, they cannot be used for properties of classes.[^1]

[^1]: `yielding borrow` and `yielding mutate` accessors can be used for properties of classes.

#### Use for subscripts

Borrowing accessors can also be used to implement subscript operations:

```swift
struct ArrayLikeType {
  subscript(index: Int) -> Element {
    borrow { .... }
    mutate { .... }
  }
}
```

Like any `borrow` or `mutate` operation, the above subscript implicitly accesses the entire struct for the duration of the property access.
In particular, the following is illegal because it creates two
mutating accesses of `x` for the duration of the function call:

```swift
var x: ArrayLikeType
swap(&x[0], &x[1])
```

## Source compatibility

This could potentially change the interpretation of an existing accessor that uses a function called `borrow` or `mutate` that takes a trailing closure parameter:

```swift
struct S {
  func borrow(closure: () -> ()) { ... }
  // Is this a new borrow accessor?
  // Or a call to the borrow method just above?
  var property: Int { borrow { ... } }
}
```

We believe the above problem is unlikely to arise in practice.

## ABI compatibility

This is a new feature that has no impact on existing ABI.

## Implications on adoption

Changing an existing non-borrowing accessor to a borrowing accessor or vice-versa is generally ABI-breaking.

However, the ABI of existential types is preserved when concrete conformers change their accessors, as long as the compiler is able to continue synthesizing a conforming accessor.

Changing an existing non-borrowing accessor to a borrowing accessor or vice-versa can be source-breaking for clients.
In particular, changing a `get` to a `borrow` creates new restrictions on clients regarding the relative lifetimes of different values.
This can cause previously working code to no longer compile.

## Future directions

### Borrowing returns

It is also useful for functions to be able to return borrowed values. As with borrowing accessors, this requires the value to have a guaranteed lifetime. It is particularly useful to extend the borrow semantics:
```swift
struct S<Value> {
  subscript(_ index: Int) -> Value {
     borrow { ... }
  }
  func indirect(_ parameter: Foo) -> borrowing Value {
     let index = ... compute index from parameter ...
     return self[index]
  }
}
```

### Borrowing via unsafe pointers

Low-level data structures are often built using unsafe pointers.
Unsafe pointers by their nature prevent the compiler from accurately diagnosing
lifetimes, which means that it must generally reject code like the following:
```swift
var _storage: UnsafePointer<Element>

var first: Element {
  borrow {
    // ERROR: borrow accessors can only return stored properties
    // or computed properties that have borrow accessors
    return _storage.pointee
  }
}
```

Supporting cases like this will require some way to annotate the return expression.
For example, we might provide a function-like marker:
```swift
var first: Element {
  borrow {
    return unsafeResultDependsOnSelf(_storage.pointee)
  }
}
```

This would assert that the result of the expression is valid at least
until the next mutating operation on `self`.

## Alternatives considered

#### Do Nothing

Yielding coroutine-based accessors provide similar functionality, but have distinctly different capabilities and performance characteristics:  Coroutine accessors can run code after the end of an access (they are semantically more capable) but that additional capability requires the client to make two function calls unless the accessor can be fully inlined.

The in-place mutation capabilities of borrowing accessors provides much of the same capability without the overhead of multiple function calls.

## Acknowledgments

The Swift Standard Library team provided impetus for this feature, especially Karoy Lorentoy, Guillaume Lessard, and Alejandro Alonso.  Valuable design advice and insights came from Andrew Trick, Nate Chandler, Joe Groff, and especially John McCall.
