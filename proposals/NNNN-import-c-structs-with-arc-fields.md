# Import C structs with ARC-managed fields

* Proposal: [SE-NNNN](NNNN-import-c-structs-with-arc-fields.md)
* Authors: [Adam Cmiel](https://github.com/AdamCmiel)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#64381](https://github.com/swiftlang/swift/pull/64381) (strong fields), [d99572b8](https://github.com/swiftlang/swift/commit/d99572b848a6b701b8505dc4f675bbfab84369db) (bridging), [swiftlang/swift#90247](https://github.com/swiftlang/swift/pull/90247) (indirect/sret), [swiftlang/swift#90062](https://github.com/swiftlang/swift/pull/90062) (weak fields)
* Review: ([pitch](https://forums.swift.org/t/pitch-import-c-structs-with-arc-pointer-members/64059))

## Summary of changes

Import C structs with `__strong` and `__weak` ARC-qualified fields as Swift
structs with correct ARC value semantics, bridging strong fields of bridgeable
ObjC type to native Swift types, behind the `ImportCStructsWithArcFields`
feature flag.

## Motivation

C structs containing ARC-qualified pointer fields (`__strong`, `__weak`) are
rejected by the Clang importer today because they are non-trivial to copy and
destroy. Swift code that needs these types must either rewrite the C API or
hand-roll `Unmanaged` juggling that is easy to get wrong.

C APIs — especially on Apple platforms — routinely vend structs that hold
object references:

```c
struct CacheEntry {
  __strong NSObject *_Nonnull object;
  __weak id _Nullable delegate;
  int64_t cost;
};
```

Today, importing this struct fails, and so does importing any function that
takes or returns it. Users fall back to `__unsafe_unretained` variants of the
API (when the library offers them) plus manual `Unmanaged` retain/release
dance, or they write an Objective-C wrapper class. Both are boilerplate-heavy
and unsound in the presence of `__weak` (which cannot be expressed with
`Unmanaged` at all).

The design was first pitched in March 2023 alongside a draft of the
strong-fields implementation; feedback there confirmed the demand (Realm
reported maintaining ObjC wrappers purely to work around the missing import)
and asked that opt-in be possible per-module through SwiftPM, which the
feature-flag approach provides.

Public C API cannot use this pattern at all: a header vending such a struct
cannot be included from plain C, where `__strong` and `__weak` are not
keywords — which is why Apple's own public headers contain no examples, only
ivars, out-parameters, and macros. The demand comes from Objective-C and
Objective-C++ codebases, where the qualifiers are available and Clang has
long supported them.

## Proposed solution

With the feature enabled, a C struct is imported whenever its non-triviality
is fully explained by ARC-qualified fields. The imported Swift struct
preserves C layout exactly and gets value semantics with correct ARC
behavior:

```swift
// struct CacheEntry { __strong NSObject *_Nonnull object;
//                     __weak id _Nullable delegate;
//                     int64_t cost; }
public struct CacheEntry {
  public init(object: NSObject, delegate: AnyObject?, cost: Int64)
  public var object: NSObject
  public weak var delegate: AnyObject?
  public var cost: Int64
}
```

`__strong` fields of bridgeable ObjC type (e.g. `NSString`) surface as native
Swift types (e.g. `String`). A C function taking or returning these structs
imports as an ordinary Swift function with matching calling convention.

The work is gated behind the experimental feature flag
`ImportCStructsWithArcFields`
(`-enable-experimental-feature ImportCStructsWithArcFields`). Without the flag,
behavior is unchanged: non-trivial records are still rejected.

## Detailed design

### Which structs are imported

A C struct is imported when every cause of non-trivial copy or destroy is an
ARC-qualified field, `__strong` or `__weak`. This is determined recursively:
nested structs are accepted when they too qualify, and each field is
classified individually. The following keep a struct rejected:

- Unions with non-trivial members, and structs containing such unions.
- Any other cause of non-triviality (e.g. C++ records with user-provided
  copy constructors or destructors keep their existing treatment).

If any non-static, non-type member of an ARC struct fails to import, the
entire struct is rejected rather than importing a subset of fields, which
would silently produce the wrong layout. `NS_SWIFT_UNAVAILABLE` still rejects
the struct and `swift_name` renaming is honored, exactly as for trivial
structs.

### Field import rules

Field nullability follows the standard importer rules: `_Nonnull` imports as
non-optional, `_Nullable` as optional, unaudited as implicitly unwrapped
optional.

- `__strong` fields import as ordinary stored properties of the imported
  object type.
- `__weak` fields import as `weak` properties. A `__weak` field must be
  nullable: `__weak` combined with `_Nonnull` is rejected (a weak slot can
  always zero out, so a non-null invariant is unrepresentable), and per the
  rule above the whole struct is rejected. A `const`-qualified `__weak`
  field is publicly read-only.

```c
struct WeaksInAStructArc {
  __weak MYObject *_Nullable myobj;
};
```

imports as:

```swift
public struct WeaksInAStructArc {
  public init()
  public init(myobj: MYObject?)
  public weak var myobj: MYObject?
}
```

### Bridged fields

A `__strong` field whose ObjC type has a native Swift bridge (e.g.
`NSString` to `String`) is exposed with the bridged type. The stored C field
becomes a private property with a `_` prefix, and a computed property with
the field's original name vends the bridged value:

```c
struct StrongNSStringArc {
  __strong NSString *_Nonnull name;
  int tag;
};
```

imports as:

```swift
public struct StrongNSStringArc {
  public init(name: String, tag: CInt)
  private var _name: NSString
  public var tag: CInt
  public var name: String
}
```

The memberwise initializer accepts the bridged Swift types. A
`const`-qualified field exposes only the getter. `__weak` fields never
bridge, even when their ObjC type has a Swift bridge: a weak slot must stay
a weak slot, and the bridged value types (`String`, `Array`, …) have no
weak-reference representation. A `__weak NSString *` field therefore stays
`weak var name: NSString?`.

### Initializers

The memberwise initializer takes all fields in order, using the bridged
types where bridging applies. A default `init()` is synthesized under the
existing rules, which in practice means it exists only when
zero-initialization is sound for every field (structs with `_Nonnull
__strong` fields get only the memberwise initializer).

### Value semantics and calling convention

Copies retain each `__strong` field and copy each weak registration;
destruction releases the strong fields and destroys the weak slots; weak
fields zero when their object deallocates. These are exactly the semantics
of the same struct in ARC C and Objective-C.

Layout is exactly the C layout. Strong-only structs are loadable values;
structs containing `__weak` fields are address-only (the ObjC runtime tracks
weak slots by address, so they cannot live in registers). Either way, the
calling convention matches Clang's for the same type, so an imported C
function taking or returning one of these structs agrees with its C callers
and callees on both sides of the boundary.

### Overrides of ObjC methods with C++ types

As companion calling-convention work, a Swift override of an
Objective-C(++) method with non-trivial C++ record types in its signature is
accepted: the override matcher already enforces compatibility with the base
declaration that Clang validated for ObjC++, so the Swift-side
representability re-check is skipped. `@objc` thunks pass such indirect
values correctly. This is the same machinery any address-only interop type —
including weak-containing ARC structs — needs in `@objc` signatures.

## Source compatibility

This proposal is purely additive: code that imports today imports identically,
and code that was previously rejected (the struct, plus any API mentioning it)
now becomes available. No existing valid program changes meaning.

Two narrow caveats, standard for importer improvements:

- A module that defined its own Swift type with the same name as a
  previously-rejected C struct will now face an ambiguity; the workaround is
  the same as for any newly imported declaration (qualification or rename).
- Manual workarounds (e.g. `__unsafe_unretained` variants, `Unmanaged`
  wrappers) keep working untouched; nothing forces migration.

## ABI compatibility

Imported structs have exactly their C layout; they are fixed-layout types.
The calling convention matches Clang's for the same type. No new runtime
entry points are added, and no existing type's ABI changes.

Changing a field's type or ARC qualifier in the C header is an ABI break, as
with any C struct. The private `_`-prefixed stored properties backing
bridged fields are part of the fixed layout but are not API.

## Implications on adoption

C headers need no changes — the feature meets existing ARC-annotated C code
where it is. Adoption is per-module via `-enable-experimental-feature
ImportCStructsWithArcFields` until the feature is finalized and the flag
removed, which answers the pitch request for SwiftPM-compatible opt-in.
Because the change is additive, libraries can adopt it without breaking
clients on older toolchains (those clients simply cannot name the newly
imported types).

## Future directions

- Support for weak-containing structs in serialized (`@inlinable`) contexts,
  which currently cannot name them.
- Rules for using ARC structs directly in `@objc` signatures, building on
  the indirect calling-convention support above.
- Strong block fields (e.g. `void (^__strong block)(void)`), which keep
  their current treatment under this proposal.
- Interaction with move-only types, which could reuse the same
  address-only strategies.

## Alternatives considered

- **Status quo: keep rejecting and document `Unmanaged` workarounds.** This
  cannot express `__weak` at all, and it pushes ARC bookkeeping onto users
  at exactly the boundary where the compiler has complete information.
  Importing `__strong` fields as `Unmanaged<T>` was also considered, but it
  leaks lifetime management to every use site and composes poorly with
  struct value semantics (copies would alias instead of retaining).
- **Make all ARC structs address-only.** Simpler and uniform, but it would
  force strong-only structs — the common case — through memory for every
  operation instead of keeping them in registers.
- **Bridging via overlays or manual computed properties.** Achieves the same
  user-visible types for hand-picked structs only; automatic synthesis keeps
  every struct consistent with no per-API adoption work.
- **Bridge weak fields too.** Rejected: a weak slot must remain a weak slot
  at the storage level, and the bridged value types have no weak-reference
  representation.

## Acknowledgments

Thanks to Akira Hatanaka, whose LLVM support for strong and weak references
in C structs and whose `@in_cxx` parameter convention and `@objc` sret fixes
are the foundation this proposal builds on; to John McCall for reviewing the
ARC-struct importer work; and to the participants in the original 2023 pitch
thread for confirming the use cases and the per-module opt-in requirement.
