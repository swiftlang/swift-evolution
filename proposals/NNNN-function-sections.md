# Section Placement Control for Functions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: https://github.com/swiftlang/swift/pull/89740
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

This proposal extends the `@section` attribute introduced in [SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md) to also allow functions to be annotated with `@section`. This can be useful in embedded systems where some code (for example the boot code for firmware) needs to be in a particular section in the binary.

## Motivation

The `@section` attribute specifies where a particular entity will be placed in an object file. Particularly in embedded environments, linkers and other tools expect certain kinds of symbols to be in specific sections. SE-0492 introduced support for `@section` for global and static variables, but left functions to a future direction. However, functions also require this support. A prominent use case is firmware entry points and booting schemes, which often require startup code to be in a predefined section:

```
// code for the function is placed into the custom section
@section("__TEXT,boot")
func firmwareBootEntrypoint() { ... }
```

This motivation was also [outlined in the Future Directions of SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md#section-placement-for-functions).

## Proposed solution

Enable the `@section` attribute on all kinds of functions, including normal functions (`func`), initializers (`init`), deinitializers (`deinit`), closures, and accessors (`get`, `set`, etc.). The detailed design provides 

## Detailed design

Functions always reside in a text section, so they have fewer limitations than The `@section` attribute can be applied to any kind of function. Some examples to show the syntax at various places:

```swif
@section("__TEXT,boot")
func firmwareBootEntrypoint() { ... }

struct MyBootConfig: ~Copyable {
  @section("__TEXT,boot") init() { 
    registerCallback { @section("__TEXT,boot") in 
      ...
    }
  }

  @section("__TEXT,boot") deinit { }

  var bootPhase: Int {
    @section("__TEXT,boot") get { ... }
    @section("__TEXT,boot") set { ... } 
  }
}
```

### Inferring `@section` on accessors and closures

When `@section` isn't explicitly specified of an accessor or a closure, it can be inferred:

* For a closure, `@section` will be inferred from its enclosing function, if it's inside a function.
  ```swift
  @section("__TEXT,boot")
  func firmwareBootEntrypoint() {
    registerCallback { // infers @section("__TEXT,boot")
      ...
    }
  }
  ```

* An accessor that provides read-only access (`get`, `borrow`, `yielding borrow`, etc.) that is synthesized by the implementation will infer `@section` from one of these accessors that was written explicitly.

* An accessor that provides read-write or write access (`set`, `mutate`, `yielding mutate`, `init`, `didSet`, `willSet`) that is synthesized by the implementation will infer `@section` from one of these accessors that was written explicitly. For example:
  ```swift
    var scratchSpace: MutableSpan<UInt> {
      @section("__TEXT,boot") borrow { ... }
      // synthesized "get" will infer @section("__TEXT,boot") from 'borrow'
      
      @section("__TEXT,boot") mutate { ... }
      // synthesized "set" will infer @section("__TEXT,boot") from 'mutate' 
    }
  ```

Note that there is no inference of `@section` from a variable to its accessors, because code and data tend to be in different sections.

### Lifting restriction on didSet/willSet

SE-0492 placed this restriction on variables with `@section`:

* the variable must not have property observers (didSet, willSet)

This restriction is unnecessary, and is lifted by this proposal. The `didSet` or `willSet` can have a `@section` attribute on them, which will then be used for inference on the actual accessor (e.g., `set`) that the implementation synthesizes a symbol for.

## Source compatibility

This is a pure extension with no source compatibility impact.

## ABI compatibility

The `@section` attribute deliberately places an entity into a specific section.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source compatibility. ABI is covered above.
