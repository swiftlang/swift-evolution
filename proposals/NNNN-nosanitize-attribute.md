# @noSanitize attribute for functions

* Proposal: [SE-NNNN](NNNN-nosanitize-attribute.md]
* Authors: [Andrew Haberlandt](https://github.com/ndrewh)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: https://github.com/swiftlang/swift/pull/91137/changes
* Review: ([pitch](tbd))

## Summary of changes

This proposal introduces a new attribute `@noSanitize(<kind>)` which can be applied to functions and subscripts in order to disable certain types of sanitizer instrumentation. This can be useful when certain code is known to trigger sanitizer false positives or cause performance issues when sanitized.
Just like the clang `__attribute__((no_sanitize("<kind>")))` attribute, the proposed Swift `@noSanitize(<kind>)` attribute prevents Swift from adding the `sanitize_address` (or `sanitize_thread`, `sanitize_memtag`, etc.) attribute to a function when emitting LLVM IR.

## Motivation

Sanitizers such as ASan and TSan rely on instrumentation to check the correctness of every memory access (e.g. by using shadow memory regions that encode whether a location is valid to access). Especially in embedded environments, sanitizers may fail to correctly track the state of certain memory locations (e.g. MMIO), causing false positives.
In other cases, some functions may deliberately (i.e. some `strlen` implementations) read beyond the bounds of a memory object, triggering undesirable (yet real) sanitizer reports.
Even when sanitizers do not produce unwanted reports, certain code may disproportionately contribute to the instrumentation overhead of a sanitizer.

## Proposed solution

Allow individual functions to be opted out of sanitizer instrumentation with an attribute. Each sanitizer is opted out independently.

## Detailed design

The `@noSanitize(<kind>)` attribute takes a single required argument naming the sanitizer to suppress. The initially supported kinds are:

- `address` — suppresses ASan (`sanitize_address`) instrumentation.
- `thread` — suppresses TSan (`sanitize_thread`) instrumentation.
- `memtag` — suppresses [MemTag](https://llvm.org/docs/MemTagSanitizer.html) stack tagging (`sanitize_memtag`) instrumentation.

Each kind opts out independently, so `@noSanitize(address)` on a function built with `-sanitize=thread` has no effect. Multiple `@noSanitize` attributes may be stacked on the same declaration to opt out of more than one sanitizer.

The attribute is accepted on any function (top-level `func`, methods, initializers, deinitializers, and accessors such as `get`/`set`/`_read`/`_modify`) and on subscripts.

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

// Stacking is allowed to opt out of more than one sanitizer.
@noSanitize(address)
@noSanitize(thread)
func hotPath() -> Int { ... }
```

### Interaction with inlining

Inlining a `@noSanitize` callee into a caller that is still being instrumented would silently re-instrument the callee's body, defeating the attribute. To preserve the guarantee, the SIL performance inliner refuses to inline a `@noSanitize(<kind>)` callee into a caller that does not carry the same `@noSanitize(<kind>)` when that sanitizer is enabled for the current build.

The restriction is one-directional: a regular (sanitized) callee may still be inlined into a `@noSanitize` caller (and thus may lose its instrumentation). Users who want a `@noSanitize` function to be inlined into ordinary sanitized code should either mark the caller with a matching `@noSanitize` or accept that the callee will remain an out-of-line call in sanitized builds. `@inline(__always)` does not override this restriction.

## Source compatibility

This is a pure extension with no source compatibility impact.

## ABI compatibility

This attribute is applied to deliberately disable sanitizer instrumentation on individual functions. In all currently supported sanitizers, functions compiled with a sanitizer are ABI-compatible with unsanitized functions.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code and is not tied to any runtime support.

## Future Directions

### Closures

The attribute is currently limited to declarations (`OnAbstractFunction | OnSubscript`), so it cannot be written on a closure expression:

```swift
registerCallback { @noSanitize(address) in ... }
```

### Globals

Some sanitizers support clang's `no_sanitize` to disable sanitization of globals. We could support a similar attribute for Swift globals.

### Additional sanitizers

Additional sanitizer kinds may need to be added in the future when supported by swiftc's -sanitize option.
