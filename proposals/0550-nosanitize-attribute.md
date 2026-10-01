# @instrumentation attribute for functions

* Proposal: [SE-0550](0550-nosanitize-attribute.md)
* Authors: [Andrew Haberlandt](https://github.com/ndrewh)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active review (September 16–30, 2026)**
* Implementation: [swiftlang/swift#91137](https://github.com/swiftlang/swift/pull/91137)
* Review: ([pitch](https://forums.swift.org/t/pitch-nosanitize-attribute-for-functions/88972)) ([review](https://forums.swift.org/t/se-0550-nosanitize-attribute-for-functions/89593))

## Summary of changes

This proposal introduces a new attribute `@instrumentation(...)` which can be applied to functions, subscripts, and closures to disable one or more kinds of compiler-inserted instrumentation (such as sanitizers). It also introduces an `instrumentation(<kind>)` compilation condition, which evaluates to true if the specific instrumentation is enabled.

## Motivation

Sanitizers such as ASan and TSan rely on instrumentation to check the correctness of every memory access (e.g. by using shadow memory regions that encode whether a location is valid to access). In embedded environments, sanitizers may fail to correctly track the state of certain memory locations (e.g. MMIO, commpage), causing false positives. Sanitizer instrumentation also imposes runtime overhead that may be unacceptable on hot code paths, so users may wish to selectively
disable instrumentation.

## Proposed solution

Allow individual functions to be opted out of compiler-inserted instrumentation with an attribute. Each kind of instrumentation is opted out independently.

## Detailed design

The `@instrumentation(disable: <kind>...)` attribute takes one or more instrumentation kinds as arguments. The initially supported kinds are:

- `address` — suppresses ASan (`sanitize_address`) instrumentation.
- `thread` — suppresses TSan (`sanitize_thread`) instrumentation.
- `memtagStack` — suppresses [MemTag](https://llvm.org/docs/MemTagSanitizer.html) stack tagging (`sanitize_memtag`) instrumentation.
- `coverage` — suppresses SanitizerCoverage instrumentation.

Kind names that represent sanitizers correspond to the lowerCamelCased form of the matching `-sanitize=` command-line flag (so `-sanitize=memtag-stack` becomes `memtagStack`).

Each kind opts out independently, so `@instrumentation(disable: address)` on a function built with `-sanitize=thread` has no effect. Multiple kinds may be listed in a single attribute (`@instrumentation(disable: address, thread)`), and multiple `@instrumentation` attributes may also be stacked on the same declaration; the two forms are equivalent.

The attribute is accepted on any function (top-level `func`, methods, initializers, deinitializers, and accessors), on subscripts, and on explicit closure expressions.

```swift
@instrumentation(disable: address)
func readsMMIO(_ p: UnsafePointer<UInt32>) -> UInt32 { p.pointee }

struct Device: ~Copyable {
  @instrumentation(disable: address) init() { ... }

  @instrumentation(disable: address) deinit { ... }

  var status: UInt32 {
    @instrumentation(disable: address) get { ... }
    @instrumentation(disable: address) set { ... }
  }

  @instrumentation(disable: address)
  subscript(i: Int) -> UInt8 { ... }
}

// Opt out of more than one kind, either as a list or by stacking.
@instrumentation(disable: address, thread)
func hotPath() -> Int { ... }
```

### Closures

`@instrumentation` on an enclosing function propagates into closures nested inside it, consistent with the behavior of `@section` from [SE-0537](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0537-section.md).

`@instrumentation` may also be written on an explicit closure expression:

```swift
registerCallback { @instrumentation(disable: address) in
  readsMMIO()
}
```

To undo propagation from an enclosing scope, use `@instrumentation(default)`. This resets any propagated settings so that the annotated declaration or closure is instrumented according to the current build's defaults. `default` may be composed with `disable:` to reset and then re-disable specific kinds:

```swift
@instrumentation(disable: address)
func outer() {
  withCallback { @instrumentation(default) in
    // Instrumented normally, even though `outer` is not.
  }

  withCallback { @instrumentation(default, disable: thread) in
    // Address instrumentation is restored; thread instrumentation is disabled.
  }
}
```

### Interaction with inlining

Inlining an `@instrumentation(disable: <kind>)` callee into a caller that is still being instrumented would silently re-instrument the callee's body, defeating the attribute. Swift will not heuristically inline such a callee into a caller that does not carry the same `@instrumentation(disable: <kind>)` when that instrumentation is enabled for the current build.

Combining `@inline(always)` with `@instrumentation(disable: ...)` on the same declaration is not supported and is diagnosed as an error. The two attributes make contradictory demands: `@inline(always)` (per [SE-0496](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md)) requires the callee to be inlined into every caller (and to diagnose cases when it cannot be), while `@instrumentation(disable:)` requires the callee's body to remain uninstrumented even when its caller is instrumented. A future proposal may define a specific behavior for this combination if a use case emerges.

### Compilation condition for enabled instrumentation

Because `@inline(always)` and `@instrumentation(disable: ...)` cannot be combined on the same declaration, a mechanism is needed to support functions that are `@inline(always)` in uninstrumented builds but out-of-line-and-uninstrumented in instrumented builds.
A new `instrumentation(<kind>)` compilation condition, with the same supported kinds as the attribute, evaluates true if the specified instrumentation is enabled. Each `instrumentation` condition may only list a single kind, but can
be combined using the usual logical operators.

```swift
#if !instrumentation(address)
@inline(always)
#else
@instrumentation(disable: address)
#endif
func f() { ... }
```

## Source compatibility

This is a pure extension with no source compatibility impact.

## ABI compatibility

This attribute is applied to deliberately disable instrumentation on individual functions. In all currently supported sanitizers, functions compiled with a sanitizer are ABI-compatible with unsanitized functions.

When `@instrumentation` is applied to an `@inlinable` function in a module built with library evolution enabled, the attribute is preserved in the textual `.swiftinterface` file.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code and is not tied to any runtime support.

## Future Directions

### Globals

Some sanitizers support clang's `no_sanitize` to disable sanitization of globals. We could support a similar attribute for Swift globals.

### Additional instrumentation kinds

Additional kinds may be added in the future as swiftc gains support for more sanitizers or other forms of compiler-inserted instrumentation.
