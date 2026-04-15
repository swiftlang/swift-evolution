# Protocol Metatype Extensions

* Proposal: [SE-NNNN](NNNN-protocol-metatype-extensions.md)
* Authors: [Saleem Abdulrasool](https://github.com/compnerd)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#88445](https://github.com/swiftlang/swift/pull/88445)
* Upcoming Feature Flag: `ProtocolMetatypeExtensions`

## Summary of changes

Allows `extension P.Protocol`, where `P` is a protocol, to declare members
that live on the protocol metatype itself and are not inherited by conforming
types.

## Motivation

Swift protocols can have static members declared in extensions:

```swift
protocol Plugin {
  static var name: String { get }
  func run()
}

extension Plugin {
  static var searchPaths: [String] { ["/usr/lib/plugins", "~/.plugins"] }
}
```

These members are inherited by all conforming types:

```swift
struct MyPlugin: Plugin {
  static var name: String { "MyPlugin" }
  func run() { ... }
}

MyPlugin.searchPaths  // returns ["/usr/lib/plugins", "~/.plugins"] -- inherited
```

This inheritance is usually the desired behavior for default implementations,
but some static members conceptually belong to the protocol *itself* rather
than to any conforming type. Search paths are a property of the plugin system,
not of any individual plugin. Today there is no way to express this distinction.

### Protocols as namespaces

Protocols are natural namespaces for metadata and utilities related to the
abstraction they define. A plugin registry, a wire format version, or a
protocol-level identifier all describe the protocol itself. But today there is
no mechanism to declare static members that live exclusively on the protocol
without leaking into every conforming type.

### Current workarounds

Developers resort to several patterns, none of which are satisfactory:

- Free functions: `func pluginSearchPaths() -> [String]` loses the
  member-access syntax and pollutes the module namespace.
- Namespace enums: `enum PluginMetadata { static var searchPaths: [String] { ... } }`
  requires inventing an unrelated type name with no connection to the protocol.
- Top-level constants: `let pluginSearchPaths = [...]` loses the association
  with the protocol entirely.
- Marker types: a struct that wraps protocol-level data and is accessed via a
  static property on the protocol, adding boilerplate and indirection.

All of these workarounds obscure the intent that the member belongs to the
protocol itself.

## Proposed solution

Allow `extension P.Protocol { ... }` to declare members on the protocol
metatype:

```swift
extension Plugin.Protocol {
  var searchPaths: [String] { ["/usr/lib/plugins", "~/.plugins"] }
}
```

Members declared in `extension P.Protocol` are:

- Accessible on the protocol metatype: `Plugin.searchPaths` works.
- Not inherited by conforming types: `MyPlugin.searchPaths` is an error.
- Statically dispatched: the extension provides the implementation directly,
  with no witness table involvement and no concrete conforming type in scope.

Because `extension P.Protocol` extends the metatype type `(any P).Type`,
members are declared as instance members of that metatype, without the `static`
keyword. The protocol name is already a value of this metatype type (implicitly
`P.self`), so `P.searchPaths` accesses the member directly.

### Example

```swift
extension Plugin.Protocol {
  var searchPaths: [String] { ["/usr/lib/plugins", "~/.plugins"] }
  var apiVersion: Int { 2 }
}

Plugin.searchPaths   // ["/usr/lib/plugins", "~/.plugins"]
Plugin.apiVersion    // 2
// MyPlugin.apiVersion  // error: not inherited

// Stored metatype values work too:
let p = Plugin.self
p.searchPaths        // ["/usr/lib/plugins", "~/.plugins"]
```

## Detailed design

### Syntax

The syntax is `extension T.Protocol { ... }` where `T` is a protocol type.
This reuses Swift's existing `.Protocol` postfix type syntax. No new keywords
are introduced.

```
extension-declaration -> 'extension' type '.Protocol' inheritance-clause? generic-where-clause? '{' extension-members '}'
```

When the compiler encounters `extension P.Protocol` where `P` is a protocol, it
strips the `.Protocol` suffix to determine the extended protocol (`P`) and
marks the extension as a protocol metatype extension.

`extension T.Protocol` where `T` is not a protocol (struct, class, or enum)
remains an error, as it is today.

### Relationship to modern metatype spellings

Swift has two metatype kinds for protocols, which in modern syntax are:

- `(any P).Type` (historically `P.Protocol`): the metatype of the existential
  type `any P`. This is a singleton type whose only value is `P.self`.
- `any P.Type` (historically `P.Type`): the existential metatype, whose values
  are metatypes of concrete types conforming to `P`.

This proposal extends `P.Protocol`, i.e. `(any P).Type`. The `.Protocol`
spelling is used because it is the established syntax in Swift today and reads
naturally in the `extension` context.

### Members as instance members of the metatype

Members in a protocol metatype extension are instance members of the metatype
type `(any P).Type`. They are declared without the `static` keyword:

```swift
extension Plugin.Protocol {
  var searchPaths: [String] { ["/usr/lib/plugins", "~/.plugins"] }
  func describe() -> String { "Plugin protocol" }
}
```

This is the natural declaration style: the extension is on a type
(`(any P).Type`), and its members are instance members of that type. The `self`
parameter has type `(any P).Type`, which is the protocol metatype value.

Because the protocol name is itself a value of the metatype type (equivalent to
`P.self`), members are accessed directly as `P.searchPaths` or
`P.describe()`, with no `.self` required.

Members are also accessible on any stored value of the metatype type:

```swift
let p = Plugin.self
p.searchPaths        // works
p.describe()         // works

func info(_ p: (any Plugin).Type) {
  p.searchPaths      // works
}
```

### Protocol refinement

Metatype extension members do not propagate through protocol refinement:

```swift
protocol P {}
protocol Q: P {}
extension P.Protocol {
  func f() {}
}

P.f()  // OK
Q.f()  // error: type 'Q' has no member 'f'
```

This follows directly from the type system. `P.Protocol` is `(any P).Type` and
`Q.Protocol` is `(any Q).Type`. These are metatypes of distinct existential
types and have no subtype relationship between them, even when `Q` refines `P`.
Subtyping between protocol metatypes exists only on the existential metatype
axis: `any Q.Type` is a subtype of `any P.Type`, but `(any Q).Type` is not a
subtype of `(any P).Type`.

This also means there is no ambiguity when multiple parent protocols declare
metatype extension members with the same name:

```swift
protocol P {}
protocol Q {}
extension P.Protocol { func f() {} }
extension Q.Protocol { func f() {} }

protocol R: P, Q {}
R.f()  // error: type 'R' has no member 'f'
```

Because metatype extension members are not inherited through refinement, `R`
does not see either `f`. There is no diamond problem to resolve. If `R` needs
`f`, it declares its own metatype extension.

### Restrictions

Members whose signatures reference the protocol's `Self` type are not permitted.
Unlike regular protocol extensions, metatype extensions have no generic
signature and do not introduce a `Self` type parameter. The `self` parameter
has the concrete type `(any P).Type` rather than the abstract `Self.Type`.

```swift
extension Plugin.Protocol {
  var searchPaths: [String] { [...] }  // OK
  func make() -> Self { ... }         // error
}
```

In a regular `extension P`, `Self` is bound to the conforming type at each call
site. Metatype extensions have no such call site; the member is invoked on the
protocol metatype directly and there is no concrete type to bind `Self` to.
Relaxing this restriction would require resolving the open question of what
`Self` means on a protocol metatype, which is left to future work.

### Name lookup

Members declared in `extension P.Protocol` are:

- Found when looking up members on the protocol metatype (the type of `P.self`).
- Not found when looking up members on a concrete type `S` that conforms to `P`.
  This differs from regular protocol extensions where members are inherited.
- Not suggested by typo correction when the base type is a concrete conforming
  type.

### Type checking

Regular protocol extension members are generic over `Self` and require
existential opening when accessed on a protocol metatype. Metatype extension
members avoid this entirely because they are non-generic. The extension has no
generic signature, and its members have concrete interface types. For example,
a method `f()` in `extension P.Protocol` has the type
`((any P).Type) -> () -> Void`, not the generic
`<Self where Self: P> (Self.Type) -> () -> Void` of a regular protocol
extension member.

Because there is no `Self` type parameter, no existential opening occurs, no
conformance requirement needs to be satisfied, and no witness table is involved.
Calls to metatype extension members are direct, non-polymorphic function calls.

Metatype extension members behave like free functions that happen to be
namespaced on the protocol. They cannot access protocol requirements (which
need a witness), they cannot reference `Self`, and they cannot be overridden
by conforming types.

### Serialization

The metatype extension flag is serialized into `.swiftmodule` files. Importing a
module preserves the distinction: members from metatype extensions remain
inaccessible on conforming types in the importing module.

### Feature flag

The feature is gated behind `-enable-experimental-feature ProtocolMetatypeExtensions`.

## Source compatibility

This proposal is purely additive. `extension P.Protocol` is currently rejected
by the compiler ("non-nominal type 'P.Protocol' cannot be extended"), so no
existing valid code is affected.

The proposal does not reserve any new keywords. The `.Protocol` postfix is
already part of Swift's type syntax.

## ABI compatibility

Protocol metatype extensions generate the same code as regular protocol
extensions. The members are dispatched statically through the extension, not
through witness tables. No new runtime support is required.

The metatype extension flag is a serialization-level concept that affects name
lookup visibility. It does not affect symbol mangling, calling conventions, or
the layout of any runtime data structures.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no
deployment constraints and without affecting source or ABI compatibility.

Libraries that adopt protocol metatype extensions should be aware that the
members will not be visible on conforming types in client code. Converting a
regular `extension P` member to `extension P.Protocol` is a source-breaking
change for clients that access the member through a conforming type. The reverse
conversion (from `extension P.Protocol` to `extension P`) is source-compatible
since it makes the member visible in strictly more contexts.

## Future directions

### Existential metatype extensions

This proposal extends the protocol metatype `(any P).Type`, which is a
singleton: the only value is `P.self`. A natural generalisation would be
extending the existential metatype `any P.Type`, where each concrete type
conforming to `P` contributes a distinct metatype value (`MyPlugin.self`,
`OtherPlugin.self`, etc.) and members dispatch on `self`:

```swift
extension Plugin.Type {
  func instantiate() -> any Plugin { self.init() }
}

// ConcreteA.self.instantiate() vs ConcreteB.self.instantiate()
// dispatch differently because self is a different metatype value
```

Instance members are not merely a stylistic choice for `P.Type` extensions;
they are necessary. Because different conforming metatypes are distinct values,
members need to dispatch on `self`, which requires them to be instance members.

By using instance members for `P.Protocol` extensions in this proposal, we
establish a uniform model: metatype extensions add instance members to metatype
values. The only difference between `P.Protocol` and `P.Type` extensions is how
many values the metatype has, one for `P.Protocol`, many for `P.Type`.

We consider this a natural future direction but out of scope for this proposal.

### Protocol metatype conformances

`extension P.Protocol` creates a precedent for the protocol metatype having its
own members. A natural next step would be allowing the protocol metatype to
conform to other protocols:

```swift
protocol Identifiable {
  var id: String { get }
}

extension Plugin.Protocol: Identifiable {
  var id: String { "Plugin" }
}
```

This would allow protocols to participate in generic algorithms that operate on
metatypes, without requiring a concrete conforming type.

### Non-protocol metatype extensions

Extending metatypes of concrete types (e.g. `extension Int.Type`) could enable
similar patterns but has different trade-offs around member resolution and
utility. This is left as a future direction.

### Conditional metatype extensions

Extensions with where clauses on associated types or protocol inheritance could
enable richer patterns:

```swift
extension Collection.Protocol where Self.Element: Hashable {
  var supportsDeduplication: Bool { true }
}
```

This requires further design work around constraint resolution on metatypes and
is left as a future direction.

## Alternatives considered

### `static` members instead of instance members

An earlier design required the `static` keyword on all members in a metatype
extension:

```swift
extension Plugin.Protocol {
  static var searchPaths: [String] { [...] }
}
```

This was rejected because it conflates two levels of indirection. The extension
is on the metatype type `(any P).Type`, so its members are naturally instance
members of that type. Requiring `static` would make them static members of the
metatype, which is the metatype-of-the-metatype, a level that has no practical
meaning. More importantly, instance members work naturally with stored metatype
values (e.g. `let p = P.self; p.searchPaths`), while static members would only
be accessible on the protocol name directly.

### `metatype extension P`

An earlier design used a `metatype` contextual keyword:

```swift
metatype extension Plugin {
  var searchPaths: [String] { [...] }
}
```

This was rejected in favor of `extension P.Protocol` because it introduces a
new keyword, while `extension P.Protocol` reuses existing syntax that already
has meaning in Swift's type system. `P.Protocol` already means "the type of the
protocol itself" in Swift, so `extension P.Protocol` reads naturally as "extend
the protocol itself." `metatype extension P` requires learning a new term for a
concept the language can already express.

### `extension P.Type`

An alternative spelling uses `.Type` instead of `.Protocol`:

```swift
extension Plugin.Type {
  var searchPaths: [String] { [...] }
}
```

In Swift's type system, `P.Type` is the existential metatype, the metatype of
some unknown concrete type conforming to `P`. `P.Protocol` is the type of the
protocol itself (the type of `P.self`). Since protocol metatype extensions
declare members on the protocol itself, not on conforming types' metatypes,
`.Protocol` is the semantically correct postfix. Using `.Type` would be
misleading: `extension P.Type` suggests extending all conforming types'
metatypes, which is the opposite of the intended non-inheritance behavior.

### Top-level functions and constants

Protocol-associated metadata can be expressed as free functions or top-level
constants:

```swift
func pluginSearchPaths() -> [String] { [...] }
let pluginSearchPaths = ["/usr/lib/plugins", "~/.plugins"]
```

These work but lose the member-access syntax (`Plugin.searchPaths`), pollute
the module namespace, and don't express the association between the value and
the protocol.

## Acknowledgments

Thank you to Freddy Kellison-Linn, John McCall, Jordan Rose, and Matthew
Johnson for discussions that helped shape this proposal.
