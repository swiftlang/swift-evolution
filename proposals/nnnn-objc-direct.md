# Direct dispatch for Objective-C-exposed declarations

* Proposal: [SE-NNNN](nnnn-objc-direct.md)
* Authors: [Peter Rong](https://github.com/DataCorrupted), [Sharon Xu](https://github.com/sharonxu)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91894](https://github.com/swiftlang/swift/pull/91894), behind `-enable-experimental-feature ObjCDirect`. Targets `rebranch` rather than `main`, because the Clang ABI it depends on ships in LLVM 23.
* Experimental Feature Flag: `ObjCDirect`
* Review: ([first pitch](https://forums.swift.org/t/pitch-introduce-objc-direct-attribute/65138)) ([second pitch](https://forums.swift.org/t/pitch-2-objcdirect-direct-dispatch-for-objective-c-exposed-methods/89708))

## Summary of changes

Adds `@objcDirect`, which exposes a Swift method, initializer, property or subscript to Objective-C without a selector or method-list entry. Objective-C calls it the way it calls an `objc_direct` method — as a plain function — rather than through `objc_msgSend`.

## Motivation

### Exposure and dispatch are welded together

Swift can describe almost everything about how a declaration is exposed to Objective-C: its selector, nullability, error convention, availability, and whether it is a class or an instance member. It cannot describe how that declaration is *dispatched*. Marking a member `@objc` always produces the same thing: an entry in the class's method list, a selector, and call sites that go through `objc_msgSend`. There is no way to say that a member should be callable from Objective-C without also being reachable by selector at runtime.

Objective-C has had that ability since 2019. `__attribute__((objc_direct))` and `@property (direct)` expose a member to callers while omitting its metadata and calling it as a plain function. So the two languages disagree about what "exposed to Objective-C" means, and the disagreement has practical costs in a mixed-language target:

* **Migration is penalized.** Rewriting a `direct` Objective-C method in Swift silently turns it back into a message-dispatched one, restoring the metadata and the indirection the Objective-C version was written to avoid. The only alternative is to leave the method in Objective-C.
* **The workaround is a hand-written shim.** To get a non-message-dispatched call from Objective-C into Swift today, one exposes a free function with a C entry point (`@_cdecl`) and calls that instead: a parallel surface maintained by hand, detached from the class, without the bridging the `@objc` thunk would have done.
* **Every exposed member pays for runtime reachability.** A member that only the Objective-C code beside it ever calls still gets a selector, a method-list entry and message-send call sites that nothing needs.
* **`@objc @implementation` cannot implement direct members.** [SE-0436][se0436] lists `objc_direct` methods among the declarations an `@implementation` extension cannot express, so a header-first class with direct members cannot move to Swift.

### What direct dispatch buys

A direct member stops paying for its Objective-C metadata — the method-list entry, the method type encoding, the selector string and its reference — and its callers make a plain function call. In one measured application (an image-processing tool driven from Objective-C, built with `-O`, on Apple silicon), making 68 Swift members direct gave:

| | `@objc` | `@objcDirect` |
|---|---|---|
| Call from Objective-C to a trivial instance method, receiver known non-`nil` | 1.96 ns | 1.12 ns |
| Property setter called from Objective-C | 2.25 ns | 0.84 ns |
| Per-pixel image kernels called from Objective-C | | 43–65% faster |
| Size of the linked binary | | −4.3 KB net, about 63 bytes per member |

A plain C call measured 0.84 ns on the same machine. Class methods are the exception; see *Implications on adoption*.

The saving is largest for members that stay inside their own image, which is the common case and the one this proposal recommends. A member called across a library boundary needs an exported symbol, and a symbol name is longer than the selector it replaces.

## Background: the direct-method ABI

**2019 — `objc_direct` lands in Clang.** `__attribute__((objc_direct))` and `objc_direct_members` removed a method's Objective-C metadata and turned its call sites into plain C calls. To stay compatible with `objc_msgSend` semantics, the *callee* did three things: it nil-checked `self`, it realized the class first (`[self self]`) if it was a class method, and it kept `_cmd` in its signature, with the caller leaving it undefined. Every direct method also had enforced hidden visibility, so no other image — and no other compiler — had a name to bind to.

**2023 — the [first pitch][pitch1] for `@objcDirect`.** It stalled on the callee-side design: with the `nil` check inside the callee, SILGen would have had to emit it, including unwrapping an `Optional` receiver before calling the Swift implementation.

**2026 — the ABI is reworked.** The preconditions moved from the callee into a thunk emitted by each caller ([LLVM RFC][llvm-rfc]):

| | 2019 design | 2026 ABI |
|---|---|---|
| Symbol | `\01-[Class sel]`, enforced hidden | `-[Class sel]D` |
| `nil` check | in the callee, unconditionally | in the caller's `-[Class sel]D_thunk`, only where the receiver may be `nil` |
| Class realization | in the callee, unconditionally | in the same thunk, only where the class may be unrealized |
| `_cmd` | in the signature, undefined | not in the signature |

The thunk is `linkonce_odr` and hidden; each translation unit that needs one emits an identical copy, and the linker folds them. [`-fobjc-direct-precondition-thunk`][pr16] and the [thunk generation][pr18] are in LLVM 23.

Two things follow for Swift. The implementation now has a stable, agreed spelling, `-[Class sel]D`, that a Clang caller in another translation unit can reference. And the preconditions belong to the caller — which, for a Swift direct member, is always Objective-C code compiled by Clang. Swift only has to emit the callee: a bare function under the agreed name.

[pitch1]: https://forums.swift.org/t/pitch-introduce-objc-direct-attribute/65138
[llvm-rfc]: https://discourse.llvm.org/t/rfc-optimizing-code-size-of-objc-direct-by-exposing-function-symbols-and-moving-nil-checks-to-thunks/88866
[pr16]: https://github.com/llvm/llvm-project/pull/170616
[pr18]: https://github.com/llvm/llvm-project/pull/170618

## Proposed solution

Add an attribute, `@objcDirect`, that can be written on a method, initializer, property or subscript of a class exposed to Objective-C:

```swift
@objc public final class Cache: NSObject {
  @objcDirect public init(capacity: Int) { … }
  @objcDirect public var capacity: Int
  @objcDirect public func lookup(_ key: String) -> NSObject? { … }
  @objcDirect public subscript(index: Int) -> NSObject? { … }
  @objc public func refresh() { … }
}
```

The generated header declares the direct members as direct, so Objective-C callers keep writing ordinary Objective-C:

```objc
@interface Cache : NSObject
- (nonnull instancetype)initWithCapacity:(NSInteger)capacity OBJC_DESIGNATED_INITIALIZER SWIFT_OBJC_DIRECT;
@property (SWIFT_OBJC_DIRECT_PROPERTY nonatomic) NSInteger capacity;
- (NSObject * _Nullable)lookup:(NSString * _Nonnull)key SWIFT_WARN_UNUSED_RESULT SWIFT_OBJC_DIRECT;
- (NSObject * _Nullable)objectAtIndexedSubscript:(NSInteger)index SWIFT_WARN_UNUSED_RESULT SWIFT_OBJC_DIRECT;
- (void)refresh;
@end
```

`[cache lookup:key]`, `cache.capacity = 8` and `cache[0]` compile to static calls. The Swift module defines one symbol per direct entry point, under Clang's spelling for the direct ABI, and none of them takes `_cmd`:

```llvm
define ptr  @"-[Cache initWithCapacity:]D"(ptr %0, i64 %1)
define i64  @"-[Cache capacity]D"(ptr %0)
define void @"-[Cache setCapacity:]D"(ptr %0, i64 %1)
define ptr  @"-[Cache lookup:]D"(ptr %0, ptr %1)
define ptr  @"-[Cache objectAtIndexedSubscript:]D"(ptr %0, i64 %1)
```

`refresh` keeps its selector, its method-list entry and its `objc_msgSend` call sites; the direct members have none of them.

Two rules govern everything else:

* **`@objcDirect` implies `@objc`.** Writing it on a member that is not already exposed adds the exposure, and the ordinary `@objc` checks apply.
* **`@objcDirect` implies static dispatch.** Anything that reaches a member through the Objective-C runtime — `#selector`, `#keyPath`, key-value coding and observing, `AnyObject` lookup, `@objc` protocol conformance, `perform(_:)`, `respondsToSelector:` — cannot reach a direct member. The compiler rejects the uses it can see; the rest fail at run time.

## Detailed design

### Where the attribute can be written

`@objcDirect` can be written on a method (instance, `static` or `class`), initializer, property or subscript of a class exposed to Objective-C. It cannot be written on an individual accessor — an accessor is direct exactly when its storage is — or on a `deinit`.

A direct member is statically dispatched, but it does not have to be `final`. It simply cannot be overridden: an override of a direct member is an error, in the same module or another one.

```swift
class Base: NSObject {
  @objcDirect func greet() {}
}
class Sub: Base {
  override func greet() {}
  // error: cannot override instance method declared '@objcDirect'; a direct
  //        declaration has no method-list entry, so an Objective-C caller
  //        would reach the superclass implementation
}
```

The member is rejected when Objective-C could not name it. Its symbol embeds the printed `@interface` name and is global, so the class has to be printed into the generated header under a name of its own. That excludes members of:

* anything but a class — a global function, or a member of a struct, enum or protocol;
* a class that is not exposed to Objective-C — a generic class, a class with generic ancestry, or a Swift class that does not derive from an Objective-C one;
* a local class, or a nested class, unless the nested class has an explicit `@objc(Name)` and every enclosing type is an explicitly `@objc` class (only those are printed, and only an explicit name keeps two nested classes apart);
* a `private` or `fileprivate` class. Nor can the member itself be `private` or `fileprivate`.

The member is rejected when Objective-C could not express it: beyond the ordinary `@objc` rules, an `async` member (there is no direct calling convention for asynchronous methods) and a subscript with more than one index.

The member is rejected when something would have to reach it dynamically:

* `override` (above), and `open`, which promises clients an override that can never be written;
* `dynamic`, written or implied by `@NSManaged`. (`-enable-implicit-dynamic`, which makes eligible declarations `dynamic` for development-time replacement, skips direct members instead; they are simply not replaceable.)
* a `required` initializer, which must be inherited;
* `@IBAction` and `@IBSegueAction` methods, which a nib or storyboard calls by selector, and `@IBOutlet`, `@IBInspectable` and `@GKInspectable` properties, which are set by key;
* an Objective-C selector that implements a requirement of a protocol the class adopts, under a different Swift name. Clang rejects a direct method that implements a protocol requirement, so the generated header would not compile:

  ```swift
  class Item: NSObject {
    @objc(hash) @objcDirect func myHash() -> Int { 0 }
    // error: instance method 'myHash()' cannot be '@objcDirect': its Objective-C
    //        selector 'hash' is a requirement of protocol 'NSObjectProtocol', and
    //        a method that implements a protocol requirement cannot be direct
  }
  ```

### Uses that need dynamic dispatch

Some otherwise valid uses of a direct member need the dynamic dispatch it does not have. They are diagnosed at the use:

* **`#selector`** naming a direct member is an error: no selector for it is registered.
* **`#keyPath`** naming a direct property is an error, and a Swift key path through a direct property carries no key-value coding string. Passing such a key path literal to an API that converts it to a string — `observe(_:options:changeHandler:)`, `publisher(for:)`, `willChangeValue(for:)` and `didChangeValue(for:)`, `NSSortDescriptor(keyPath:ascending:)`, `NSExpression(forKeyPath:)` — is an error, because each of them traps without the string. A key path that is not a literal at the call still traps at run time.
* **`AnyObject` lookup** does not find direct members, matching how `objc_direct` members imported from Objective-C are already treated.
* **Witnessing an `@objc` protocol requirement** is an error, since a call through the protocol is a message send. Witnessing a Swift protocol requirement is fine: the witness calls the member statically.

For members imported from Objective-C as `objc_direct`, the `#selector` and `#keyPath` checks apply only when the feature is enabled; see *Source compatibility*.

### Properties and subscripts

A property or subscript is direct as a whole. Each accessor becomes a direct entry point named for its selector — `-[Cache capacity]D` and `-[Cache setCapacity:]D`, `-[Cache objectAtIndexedSubscript:]D`, `-[Store objectForKeyedSubscript:]D` — and an accessor with narrower access, such as the setter of a `public private(set) var`, gets the narrower visibility. The accessors of a `static` or `class` property are class methods: `+[Cache shared]D`.

A property attribute cannot be spelled with `__attribute__`, so the generated header marks a direct property with `SWIFT_OBJC_DIRECT_PROPERTY`, which expands to `direct,` where Clang supports it. A class property's accessors are also declared, with `SWIFT_OBJC_DIRECT`, and a subscript is printed as its accessor methods:

```objc
@property (SWIFT_OBJC_DIRECT_PROPERTY nonatomic, readonly) NSInteger hits;
SWIFT_CLASS_PROPERTY(@property (SWIFT_OBJC_DIRECT_PROPERTY nonatomic, class, readonly, strong) Cache * _Nonnull shared;)
+ (Cache * _Nonnull)shared SWIFT_WARN_UNUSED_RESULT SWIFT_OBJC_DIRECT;
```

A direct stored property keeps its instance variable, with an empty type encoding; see *Key-value coding and observing*.

### Initializers

A direct initializer is emitted like any other direct member, under its selector (`-[Cache initWithCapacity:]D`), and is called statically. That interacts with subclassing. A subclass can neither override a direct initializer nor hide it: Clang forbids redeclaring a direct method in a subclass's `@interface`, even as unavailable. So if a class with a direct *designated* initializer could be subclassed, Objective-C could run that initializer on an instance of the subclass — directly, or through a convenience initializer that delegates to it — and the subclass's stored properties would never be initialized. The rules close that off for Swift classes:

* **A direct designated initializer requires a `final` class.** Direct convenience initializers are allowed in any class. The error comes with a fix-it that adds `final` (except on an `open` class, which cannot be final) and with a note describing the alternative for a class that must stay subclassable:

  ```swift
  class Base: NSObject {
    @objcDirect init(value: Int) { super.init() }
    // error: an '@objcDirect' designated initializer requires class 'Base' to be 'final'
    // note: a subclass can neither override nor hide a direct initializer, so
    //       Objective-C could call it on a subclass instance without initializing
    //       the subclass's stored properties
    // note: to keep 'Base' subclassable, make this a convenience initializer that
    //       delegates to a designated initializer that is not '@objcDirect'
  }
  ```

  Members of an `@objc @implementation` class are exempt: such a class is declared in Objective-C and follows its rules.

* **Direct initializers are not inherited.** A subclass inherits neither a superclass's direct initializer nor, when the superclass has a direct designated initializer, any of its convenience initializers, since they would reach the direct one statically and skip the subclass's initialization. With the feature enabled, the same holds for a designated initializer imported from Objective-C as `objc_direct`. If a class is left with no initializers this way, the error says why:

  ```
  error: class 'Sub' has no initializers
  note: initializer 'init(seed:)' of 'Base' is direct, so it is not inherited
  ```

* **`self.init` delegation to a direct initializer is a static call** — to the Swift initializing entry point of a Swift initializer, or, with the feature enabled, to the entry point of an imported one, through Clang's thunk.

A Swift subclass of an Objective-C-declared class — plain Objective-C, or `@objc @implementation` — can still be initialized from Objective-C through the superclass's direct designated initializer, and nothing in a header can prevent it. Swift code can reach the same state through a superclass class method that constructs `Self` with that initializer. The compiler warns when such a subclass adds stored properties:

```
warning: Objective-C can initialize 'Sub' with direct initializer 'initWithSeed:' of 'Base',
         which skips the stored properties 'Sub' adds; it cannot be overridden or marked
         unavailable in 'Sub'
```

The warning belongs to the `ObjCDirectInitialization` diagnostic group, so a project built with `-warnings-as-errors` can keep it a warning with `-Wwarning ObjCDirectInitialization`.

### Key-value coding and observing

A direct property's accessors are not in the class's method list, so key-value coding cannot find them. Key-value coding would then fall back to the instance variable — writing the storage behind the property's back, skipping `willSet` and `didSet`, and storing an object without retaining it, because a Swift class publishes no instance-variable layout. To prevent that, the instance variable of a direct property is emitted with an empty type encoding, as Swift storage that is not `@objc` already is, and key-value coding raises `NSUnknownKeyException` instead.

In practice:

* `value(forKey:)` and `setValue(_:forKey:)` raise for a direct property, as do string-keyed APIs built on them: `NSPredicate`, `NSSortDescriptor(key:)`, bindings, `setValuesForKeys(_:)`.
* Key-value observing never notifies for a direct setter, which never goes through the KVO machinery. Registering an observer with `.initial`, or a manual `willChangeValue(forKey:)` while an observer asks for values, raises.
* This differs from Objective-C, where a `@property (direct)` keeps answering key-value coding through its `_ivar`. Moving such a property to Swift turns string-keyed access to it into a run-time exception, so it should be audited for first.

### `@objc @implementation`

A member of an `@objc @implementation` extension may be `@objcDirect`, and must be exactly when the header declaration it implements is `objc_direct`:

```objc
@interface Widget : NSObject
- (int)plainMethod;
- (int)directMethod __attribute__((objc_direct));
@property (direct, readonly, getter=isDirty) BOOL dirty;
@end
```

```swift
@objc @implementation extension Widget {
  func plainMethod() -> Int32 { 2 }
  @objcDirect func directMethod() -> Int32 { 1 }
  @objc(dirty) @objcDirect var isDirty: Bool { @objc(isDirty) get { false } }
}
```

A mismatch is diagnosed in either direction, with a fix-it to add or remove the attribute: if the header says `objc_direct` and the implementation does not, callers reference a direct symbol nothing defines; if the implementation says it and the header does not, callers message a selector that was never registered. A direct property's accessors are reached through symbols spelled with their selectors, so renamed accessors (`getter=`, `setter=`) must be matched too, and a mismatch is diagnosed with the selector to add. A stored property cannot rename its accessors, so it has to become a computed property over separate storage.

The directness check applies only with the feature enabled; without it, a header's `objc_direct` member is implemented as an ordinary `@objc` member, as before.

### Code generation

A member exposed to Objective-C already has a foreign entry point — the `@objc` thunk that bridges arguments and results — and `@objcDirect` reuses it. Only the symbol and the signature change: the thunk is emitted under the direct name, without `_cmd`, and is left out of the class's Objective-C metadata. There is no new lowering and no second entry point. Swift callers of a direct member keep calling the native Swift entry point.

The symbol is `-[Class selector]D` for an instance member and `+[Class selector]D` for a class member, where `Class` is the **printed `@interface` name** — the class's `@objc(Name)` if it has one, otherwise its Swift name — and never the mangled runtime name, which no Objective-C caller sees. A method-level `@objc(name)` renames the selector segment; a `throws` member takes the usual trailing `NSError **`:

```llvm
define void @"-[PlainClass renamedSelector]D"(ptr %0)                  ; @objc(renamedSelector)
define void @"-[CustomName ping]D"(ptr %0)                              ; @objc(CustomName) class
define ptr  @"-[Throwing throwableWithCond:error:]D"(ptr %0, i64 %1, ptr %2)
```

The generated header marks direct members with macros that its preamble guards on `__has_attribute(objc_direct)`, so it stays usable with a compiler that does not know the attribute:

```objc
#if !defined(SWIFT_OBJC_DIRECT)
# if __has_attribute(objc_direct)
#  define SWIFT_OBJC_DIRECT __attribute__((objc_direct))
# else
#  define SWIFT_OBJC_DIRECT
# endif
#endif
#if !defined(SWIFT_OBJC_DIRECT_PROPERTY)
# if __has_attribute(objc_direct)
#  define SWIFT_OBJC_DIRECT_PROPERTY direct,
# else
#  define SWIFT_OBJC_DIRECT_PROPERTY
# endif
#endif
```

With the feature enabled, Swift code that calls an Objective-C `objc_direct` member calls it through Clang's precondition thunk, exactly as an Objective-C caller would; enabling the feature turns on the corresponding Clang option for the Swift compiler's own Clang instance.

### Linking and visibility

**Visibility follows access.** A direct entry point whose *effective* access is public gets default visibility and is exported; anything else is hidden. Nothing takes the address of a hidden entry point, so the linker can strip it if nothing calls it, which is where most of the size saving for internal members comes from. A public entry point, like every public Swift symbol, is kept.

```llvm
define        void @"-[Visibility publicDirect]D"(ptr %0)
define hidden void @"-[Visibility internalDirect]D"(ptr %0)
define hidden void @"-[Visibility packageDirect]D"(ptr %0)
```

**Same-image Objective-C callers.** The recommended configuration — a member called only from Objective-C inside its own image — is expressed by declaring it `internal`. The generated header for a module that is not externally consumed, such as an app target, is emitted at `internal` access, so Objective-C code sees the declaration and links against a hidden symbol. A framework emits a public-only header by default; to give Objective-C code inside the framework its internal direct members, it needs a header generated with `-emit-clang-header-min-access internal`, kept out of the public headers.

**Unique class names.** The symbol carries only the printed class name, so two classes printed under the same name — internal classes with the same name in two modules linked into one image, say — would define the same symbol and fail to link. A class with direct members should have a unique Objective-C name, as Objective-C convention already expects.

**Flag agreement.** The `D` suffix only appears under the precondition-thunk ABI, so every Objective-C translation unit that imports the generated header must be built with `-fobjc-direct-precondition-thunk`. One built without it references the old, unsuffixed name, and the link fails. That is the intended failure: it is loud, it happens at build time, and it names the symbol, whereas agreeing on a name while disagreeing about `_cmd` would be a silent calling-convention mismatch.

### Module interfaces and serialization

`@objcDirect` is serialized in binary modules and printed in textual interfaces. A module interface records the feature in its `swift-module-flags`, so it rebuilds without extra options, and declarations that use the attribute are guarded by `$ObjCDirect`, as for other experimental features:

```swift
// swift-module-flags: -target arm64-apple-macosx14.0 -enable-experimental-feature ObjCDirect -module-name Mod …
@objc final public class Cache : ObjectiveC::NSObject {
  #if compiler(>=5.3) && $ObjCDirect
  @objcDirect @objc final public func lookup(_ key: Swift::String) -> ObjectiveC::NSObject?
  #endif
}
```

The Clang option is not recorded; enabling the feature implies it. Dropping the attribute from interfaces instead would also make them rebuildable, but a header generated from a module rebuilt that way would lose `SWIFT_OBJC_DIRECT`, and Objective-C callers would message a selector the member does not have.

## Source compatibility

Writing `@objcDirect` requires the experimental feature, so nothing changes for code that does not write it — with the exceptions below, which concern members imported from Objective-C as `objc_direct`.

* **Not gated on the feature:** an imported direct method that witnesses an `@objc` protocol requirement is now an error. It was previously accepted, and every call made through the protocol failed at run time with an unrecognized selector; Objective-C forbids the same shape (`err_objc_direct_protocol_conformance`).
* **Gated on the feature:** `#selector` and `#keyPath` naming an imported direct member. These would break existing code — a Swift caller writing `NSStringFromSelector(#selector(getter: …))` for a direct property declared in a header, for instance, which works today only because key-value coding falls back to the Objective-C instance variable. Gating gives adopters time to remove them.
* **Gated on the feature:** a designated initializer imported as `objc_direct` is no longer inherited by Swift subclasses, nor are the superclass's convenience initializers, and `self.init` delegation to it becomes a static call. Without the feature, delegation stays a message send, which fails with an unrecognized selector when `self` is an instance of the class itself, and a Swift subclass's generated header still redeclares the initializer, which Clang rejects.

## ABI compatibility

Adding or removing `@objcDirect` **changes the member's Objective-C ABI**: the symbol changes, the member leaves or rejoins the method list, and calls change from message sends to direct calls. Objective-C callers must be recompiled, so the attribute is ABI-breaking to add and to remove on a member that Objective-C code outside the module calls.

For the Swift ABI, a direct member is statically dispatched and takes no vtable entry, so the attribute has the same effect as `final`. On a member that is already `final`, or of a `final` class, nothing changes: the native entry point is the same, and Swift callers keep using it. On a non-final public member of a class built with library evolution, adding the attribute removes the member's dispatch thunk and method descriptor, and removing it adds them back, so either direction breaks Swift clients compiled against the other — exactly as adding or removing `final` would. The compiler's API and ABI checks treat the attribute as breaking to add and to remove.

The proposal does not change code generation for any declaration that does not carry the attribute, except for the imported-initializer behavior under the feature described above.

## Implications on adoption

**The feature requires Clang's precondition-thunk ABI**, `-fobjc-direct-precondition-thunk`. The flag exists in Clang 22, but the thunk generation that gives it meaning is in Clang 23, so Clang 23 is the real floor. That is why the implementation is based on `rebranch`.

**Every Objective-C translation unit that imports the generated header must use the same flag**, which makes it a build-wide setting. The flag is in production use in large applications, and Clang's driver records the intent to make it the default; once it is, this constraint disappears and `@objcDirect` could be enabled by default in Swift as well.

**`@objcDirect` is a contract** that the member will not be reached dynamically. The compiler enforces what it can see; it cannot see:

* **`respondsToSelector:`**, which returns `NO` for a direct member. This is the one failure that is silent in both directions — a feature-detection branch simply takes the other path — and the first thing to audit for.
* **Selectors and keys built at run time** — `NSSelectorFromString`, `perform(_:)`, string-keyed key-value coding (which raises; see above), key paths that are not literals.
* **Protocol-qualified Objective-C receivers.** Clang does not diagnose a call to a direct method through an `id<Protocol>` receiver; it becomes an unrecognized selector at run time.
* **Test doubles that stub by selector**, which stop intercepting — a failure in test runs rather than in production.

**Initializers need a plan.** A class with a direct designated initializer is `final`; a class that must stay subclassable keeps a designated initializer that is not direct and makes the direct ones convenience initializers.

**Availability needs care.** Clang links a call to a direct method strongly, even when the declaration is available only on an OS newer than the caller's deployment target, so a back-deployed caller fails to launch against an older library instead of weak-linking. Until Clang emits weak references for such calls, availability-gated public API should not be direct.

**Direct class methods save metadata, not time.** The caller still makes sure the class is realized before calling, and today that costs a message send on every call, which can make a direct class method slower than an ordinary one (2.25 ns against 1.68 ns in the measurement above). Instance members do not pay it.

**Development builds keep working.** `-enable-implicit-dynamic` leaves direct members non-replaceable rather than rejecting them.

**Adoption is reversible in source**, but reversing it is an Objective-C ABI change, and for a non-final public member of a resilient class a Swift ABI change too.

## Future directions

### An attribute for all members of a class

Objective-C has `objc_direct_members`, and a class-level spelling would avoid repeating the attribute and compose with `@objcMembers`. It raises questions the per-member form does not — mainly how it interacts with the applicability rules, since a class typically has members that cannot be direct — and is better designed on top of settled per-member semantics.

### Safer subclassing of Objective-C-declared classes

The remaining initialization hole concerns Swift subclasses of Objective-C-declared classes with direct designated initializers. The direct routes cannot be closed, but the convenience ones could: the compiler could synthesize, in the subclass, trapping stubs marked unavailable for the superclass's non-direct convenience initializers, as it already does for designated initializers a subclass does not inherit. Inheritance could also be decided per initializer, so that convenience initializers that provably do not reach a direct one stay inherited.

### Code generation in Clang

Two costs above are Clang's to remove: realizing the class for a direct class method without a message send, and weak-linking direct calls to availability-gated methods. Neither needs a language change.

## Alternatives considered

### Putting the export decision in the attribute

Directness and visibility are independent in Objective-C, and the attribute could carry an export choice, so that a `public` member could be direct without being exported. We did not adopt it: it would duplicate access control with a second mechanism that can disagree with the first, it would be the only attribute in Swift that overrides access-derived linkage, and `internal` already covers the recommended same-image case. What remains — a member that must be `public` for Swift clients while its Objective-C symbol is only called within its image — reads more like a missing access level than like a parameter on this attribute. This is the part of the design we hold most loosely.

### Requiring `final`

The first pitch required direct members to be `final`. That is stronger than necessary — a non-final member that is never overridden is dispatched statically all the same — and a member of an `@objc @implementation` extension cannot be `final`. The proposal instead diagnoses overrides, and requires `final` only of a class with a direct designated initializer, where subclassing itself is the problem.

### A run-time check for direct designated initializers

Instead of requiring a `final` class, the direct designated initializer's entry point could trap unless `self` is exactly its class. That would keep open classes with direct designated initializers, but it catches only the direct call: a non-direct convenience initializer that delegates to the direct one, sent by Objective-C to a subclass, reaches it without passing through the checked entry point. It would also turn a build error into a run-time crash.

### Keeping the key-value coding fallback

Objective-C keeps key-value coding working for a direct property through its instance variable, and Swift could have done the same by keeping the type encoding. For a Swift class that fallback is unsafe — it skips observers and stores objects without retaining them — so the proposal makes key-value coding raise, consistent with `#keyPath` being rejected and Swift key paths carrying no string.

### Keeping a dispatch thunk for resilience

For a non-final public member of a resilient class, the compiler could keep emitting a dispatch thunk and method descriptor so that adding `@objcDirect` would not break Swift clients. They would advertise a vtable entry that can never be overridden. The proposal treats the attribute as ABI-breaking instead, as `final` is.

[se0436]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0436-objc-implementation.md
