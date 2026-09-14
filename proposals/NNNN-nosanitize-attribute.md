# @noSanitize attribute for functions

* Proposal: [SE-NNNN](NNNN-nosanitize-attribute.md]
* Authors: [Andrew Haberlandt](https://github.com/ndrewh)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: https://github.com/swiftlang/swift/pull/91137/changes
* Review: ([pitch](tbd))

## Summary of changes

This proposal introduces a new attribute `@noSanitize(<kind>...)` which can be applied to functions, subscripts, and closures to disable one or more kinds of sanitizer instrumentation. It also introduces a `sanitized(<kind>)` compilation
condition, which evaluates truthy the specific sanitizer is enabled.

## Motivation

Sanitizers such as ASan and TSan rely on instrumentation to check the correctness of every memory access (e.g. by using shadow memory regions that encode whether a location is valid to access). In embedded environments, sanitizers may fail to correctly track the state of certain memory locations (e.g. MMIO, commpage), causing false positives. Sanitizer instrumentation also imposes runtime overhead that may be unacceptable on hot code paths, so users may wish to selectively
disable instrumentation.

## Proposed solution

Allow individual functions to be opted out of sanitizer instrumentation with an attribute. Each sanitizer is opted out independently.

## Detailed design

The `@noSanitize(<kind>...)` attribute takes one or more sanitizer kinds as arguments. The initially supported kinds are:

- `address` — suppresses ASan (`sanitize_address`) instrumentation.
- `thread` — suppresses TSan (`sanitize_thread`) instrumentation.
- `memtag` — suppresses [MemTag](https://llvm.org/docs/MemTagSanitizer.html) stack tagging (`sanitize_memtag`) instrumentation.
- `coverage` — suppresses SanitizerCoverage instrumentation.

Each kind opts out independently, so `@noSanitize(address)` on a function built with `-sanitize=thread` has no effect. Multiple kinds may be listed in a single attribute (`@noSanitize(address, thread)`), and multiple `@noSanitize` attributes may also be stacked on the same declaration; the two forms are equivalent.

The attribute is accepted on any function (top-level `func`, methods, initializers, deinitializers, and accessors), on subscripts, and on explicit closure expressions.

```swift
@noSanitize(address)
func readsMMIO(_ p: UnsafePointer<UInt32>) -> UInt32 { p.pointee }

struct Device: ~Copyable {
  @noSanitize(address) init() { ... }

  @noSanitize(address) deinit { ... }

  var status: UInt32 {
    @noSanitize(address) get { ... }
    @noSanitize(address) set { ... }
  }

  @noSanitize(address)
  subscript(i: Int) -> UInt8 { ... }
}

// Opt out of more than one sanitizer, either as a list or by stacking.
@noSanitize(address, thread)
func hotPath() -> Int { ... }
```

### Closures

`@noSanitize` may also be written on an explicit closure expression:

```swift
registerCallback { @noSanitize(address) in
  readsMMIO()
}
```

`@noSanitize` on an enclosing function does *not* propagate into closures nested inside it.

### Interaction with inlining

Inlining a `@noSanitize` callee into a caller that is still being instrumented would silently re-instrument the callee's body, defeating the attribute. Swift will not heuristically inline a `@noSanitize(<kind>)` callee into a caller that does not carry the same `@noSanitize(<kind>)` when that sanitizer is enabled for the current build.

Combining `@inline(always)` with `@noSanitize` on the same declaration is not supported and is diagnosed as an error. The two attributes make contradictory demands: `@inline(always)` (per [SE-0496](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md)) requires the callee to be inlined into every caller (and to diagnose cases when it cannot be), while `@noSanitize` requires the callee's body to remain uninstrumented even when its caller is instrumented. A future proposal may define a specific behavior for this combination if a use case emerges.

### Compilation condition for enabled sanitizers

Because `@inline(always)` and `@noSanitize` cannot be combined on the same declaration, a mechanism is needed to support functions that are `@inline(always)` in non-sanitized builds but out-of-line-and-uninstrumented in sanitized builds.
A new `sanitized(<kind>)` compilation condition, with the same supported kinds as `noSanitize`, will evaluate truthy if the specified sanitizer is enabled. Each `sanitized` condition may only list a single sanitizer kind, but can
be combined using the usual logical operators.

```swift
#if !sanitized(address)
@inline(always)
#endif
@noSanitize(address)
func f() { ... }
```

## Source compatibility

This is a pure extension with no source compatibility impact.

## ABI compatibility

This attribute is applied to deliberately disable sanitizer instrumentation on individual functions. In all currently supported sanitizers, functions compiled with a sanitizer are ABI-compatible with unsanitized functions.

When `@noSanitize` is applied to an `@inlinable` function in a module built with library evolution enabled, the attribute is preserved in the textual `.swiftinterface` file.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code and is not tied to any runtime support.

## Future Directions

### Globals

Some sanitizers support clang's `no_sanitize` to disable sanitization of globals. We could support a similar attribute for Swift globals.

### Additional sanitizers

Additional sanitizer kinds may need to be added in the future when supported by swiftc's -sanitize option.
