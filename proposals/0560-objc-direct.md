# Direct dispatch for Objective-C-exposed methods

* Proposal: [SE-0560](0560-objc-direct.md)
* Authors: [Peter Rong](https://github.com/DataCorrupted), [Sharon Xu](https://github.com/sharonxu)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91894](https://github.com/swiftlang/swift/pull/91894),
  behind `-enable-experimental-feature ObjCDirect`. Targets `rebranch` rather than `main`,
  because the clang ABI it depends on ships in LLVM 23.
* Experimental Feature Flag: `ObjCDirect`
* Review: ([first pitch](https://forums.swift.org/t/pitch-introduce-objc-direct-attribute/65138))

## Summary of changes

Adds `@objcDirect`, which exposes a Swift method to Objective-C as a *direct* method: no
selector, no method-list entry, and a static call in place of `objc_msgSend`. Trades the
ability to reach the method through the Objective-C runtime for a reduction in metadata
and dispatch overhead.

## Motivation

### The interoperability surface is incomplete

Swift can describe almost everything about how a declaration is exposed to Objective-C — its
selector, its nullability, its error convention, its availability, whether it is a class or
an instance method. It cannot describe how that declaration is *dispatched*. Marking a method
`@objc` always produces the same thing: an entry in the class's method list, a selector, and
call sites that go through `objc_msgSend`. There is no way to say that a method should be
callable from Objective-C without also being reachable by selector at runtime.

Objective-C itself has not had that limitation since 2019.
`__attribute__((objc_direct))` exposes a method to callers while omitting its metadata and
calling it as a plain function. So the two languages disagree about what "exposed to
Objective-C" means: an Objective-C method may opt out of dynamic dispatch, and the Swift
method declared beside it — doing the same job, called from the same place — may not.

That is a gap in the interoperability surface rather than an optimization in search of a
justification. Swift's Objective-C interop exists so the two languages can meet as equals
within one target, and on this one axis they do not.

The gap was not straightforwardly closable until recently, which is why it has stayed open.
Objective-C's direct methods were a clang-internal code-generation technique: no stable
symbol another compiler could bind to, and no stated contract about which side emitted the
runtime preconditions. Both were fixed in LLVM 23, Objective-C-first and upstream. That work
is described under *Background*, and it is the reason the Swift change proposed here is a
small one.

### Cross-language ergonomics

The asymmetry has a practical edge for anyone maintaining a mixed-language target.

**Migration is penalized.** Rewriting a `direct` Objective-C method in Swift silently
converts it back to message dispatch, restoring the metadata and the indirection that the
Objective-C version was deliberately written to avoid. A change that ought to be
behaviour-preserving is a regression, and the author has no way to say otherwise short of
leaving the method in Objective-C.

**The alternative is a hand-written shim.** Failing that, the way to get a
non-message-dispatched call from Objective-C into Swift today is to expose a free function
with a C entry point and call that instead. It works, but it is a parallel surface maintained
by hand, unattached to the class the method belongs to, and it forfeits the bridging the
`@objc` thunk would have done for free.

**Exposure and dispatch cannot be decided separately.** `@objc` settles both at once. An
author who wants a method reachable from the Objective-C code next to it, and nothing more,
cannot say so, and pays for a runtime entry point nothing ever looks up. The same coupling
runs one level down, into which symbols get exported; *Controlling export* takes that up.

### Size

A direct method stops paying for its Objective-C metadata: the method-list entry, and the
selector string that names it.

Where the symbol does not need to be exported, that is the whole story — the metadata is
simply gone. That covers an `internal` method, and equally a `public` one whose callers all
live in the same image, since the unused export can be stripped at link time.

Where the symbol does need to be exported, there will be a small size regression, that's the same for ObjC or Swift.
The selector string goes away, but a symbol name arrives in its place, and the symbol name is the longer
of the two: it carries the class name and the direct-ABI decoration on top of the same
selector. A selector is also shared by every caller within an image, whereas an imported
symbol is paid for by each image that calls it.

Overall, the shape is a clear win for methods that stay inside their own image, which is the common
case and the one this proposal recommends, and a loss for methods called across a library
boundary. A more detailed measurements of size impact are in *Implications on adoption*.

## Background: how the ABI got here

Direct dispatch is not a new idea, and this proposal is the last step of a plan rather than
the first. The two earlier stages are worth setting out, because much of what would
otherwise look like arbitrary restriction in the design below is inherited from them.

**2019 — `objc_direct` lands in clang.** Pierre Habouzit implemented
`__attribute__((objc_direct))` and `__attribute__((objc_direct_members))`, first released in
clang 10. The attribute removed a method's Objective-C metadata and turned its call sites
into plain C calls. To stay compatible with `objc_msgSend` semantics it took three
precautions, all of them on the callee side:

* the implementation nil-checks `self`, which on arm64 is typically a single `cbz`;
* a class method first emits `[self self]`, because the class may not yet be realized;
* `self` and `_cmd` both stay in the signature, with the caller leaving `_cmd` undefined and
  the callee loading the selector only if the body refers to it.

It also gave every direct method **enforced hidden visibility**, with the consequence, in the
original commit's words, that "such direct calls are hence unreachable cross image. An
explicit C function must be made if so desired to wrap them."

Three of those decisions still govern this proposal. The callee-side nil check is what
stalled the Swift attribute in 2023. The hidden-visibility rule is the subject of
*Controlling export*. And Habouzit recorded the class-realization cost as unfinished
at the time — "long term we might want to emit something better that the optimizer can reason
about. When inlining kicks in, these calls aren't optimized away" — which is the cost this
proposal measures for class methods, and which *Cheaper class realization* leaves open.

**2023 — the Swift attribute is pitched, and stalls.** The [first pitch][pitch1] proposed
essentially this feature. It ran into the first of those decisions: with the nil check inside
the callee, SILGen would have had to emit the check itself, including unwrapping an
`Optional`-typed receiver before calling the underlying Swift function. That is real
complexity in a part of the compiler where it is not welcome, for a feature whose entire
justification is that it should be cheap.

**2026 — the ABI is reworked in clang.** Rather than work around the callee-side design, we
changed it, upstream and Objective-C-first ([LLVM RFC][llvm-rfc]). The implementation is now
emitted bare, and the preconditions move to the caller:

| | 2019 design | 2026 ABI |
|---|---|---|
| Symbol | `\01-[Class sel]`, enforced hidden | `-[Class sel]D` |
| `nil` check | in the callee, unconditionally | in `-[Class sel]D_thunk`, and only where the caller cannot prove the receiver non-`nil` |
| Class realization | `[self self]` in the callee, unconditionally | in the same thunk, and only where the class may still be unrealized |
| `_cmd` | in the signature, left undefined by the caller | not in the signature at all |

The thunk is `linkonce_odr` and hidden, so it is emitted by each caller rather than by the
definition — every translation unit that needs one gets an identical copy, and the linker
folds them.

The important part is the word *only*. Clang chooses the callee per call site: if the
receiver is provably non-`nil` — and, for a class method, the class provably realized — the
call goes straight to `-[Class sel]D` and no thunk is materialized at all, since generation
is lazy. Under the 2019 design both checks lived in the callee, so every caller paid for them
on every call whether or not that call could fail them. Moving the preconditions out did not
merely relocate the cost; it made the cost conditional, and that is what makes the direct
implementation a plain function the caller can reason about.

The [`-fobjc-direct-precondition-thunk` flag][pr16] and the [thunk generation][pr18] have
landed in LLVM 23. This means turned direct methods ABI from a clang-internal code-generation trick
into something two compilers can meet on.

**The symbol became something another compiler can reference.** Under the 2019 rules a direct
method had enforced hidden visibility, so no other translation unit had a name to link
against — the sanctioned way to cross that boundary was to hand-write a C wrapper. A
Swift-defined direct method was therefore not merely unimplemented but structurally
impossible: whatever Swift emitted, a clang caller elsewhere had nothing to bind to. The 2026
ABI gives the implementation a stable, agreed spelling, `-[Class sel]D`, and that is what lets
the two languages meet at all.

**The preconditions acquired an owner.** The 2019 design never stated, as a contract, who was
responsible for the `nil` check and the realization — it simply happened to be whoever emitted
the body. A Swift implementation would have had to reproduce that behaviour in SILGen and keep
it in step with clang's indefinitely. Under the new ABI the preconditions belong to the caller,
and the caller of a Swift direct method is always clang, since being callable from Objective-C
is the whole point. The entire precondition story therefore stays on the clang side, and this
proposal has to specify only *callee* generation: a bare function, under the agreed name, with
the agreed signature. That is the single largest reason the Swift change is as small as it is.

**Now — the Swift surface.** What is left for Swift is the callee, and little else: the
existing `@objc` thunk, reused almost unchanged, given external linkage and the agreed name.
That is the whole of the code generation described below, and the ABI it targets was designed
with this use in mind.

[pitch1]: https://forums.swift.org/t/pitch-introduce-objc-direct-attribute/65138
[llvm-rfc]: https://discourse.llvm.org/t/rfc-optimizing-code-size-of-objc-direct-by-exposing-function-symbols-and-moving-nil-checks-to-thunks/88866
[pr16]: https://github.com/llvm/llvm-project/pull/170616
[pr18]: https://github.com/llvm/llvm-project/pull/170618

## Proposed solution

One attribute, applied to a method that is already exposed to Objective-C. Here it is end to
end — the Swift declaration, the generated header, and the emitted code — with an ordinary
`@objc` method alongside for contrast:

```swift
@objc public class Cache: NSObject {
  @objcDirect public final func lookup() -> Int { 42 }
  @objc       public       func refresh() {}
}
```

```objc
// Cache-Swift.h
@interface Cache : NSObject
- (NSInteger)lookup SWIFT_WARN_UNUSED_RESULT SWIFT_OBJC_DIRECT;
- (void)refresh;
@end
```

```llvm
; the direct method: a plain function taking only self
define i64 @"-[Cache lookup]D"(ptr %0)

; the @objc method: a selector-dispatched thunk, taking self and _cmd
define internal void @"$s…7refreshyyFTo"(ptr %0, ptr %1)
@"\01L_selector_data(refresh)"
```

Objective-C callers write `[cache lookup]` exactly as they would for any other method. The
difference is what the compiler does with it: a static call instead of an `objc_msgSend`, no
`refresh`-style selector, and no entry in the class's method list. The `D` suffix is clang's
marker for the direct ABI, so the name matches what a clang caller emits for the same
declaration.

What the caller actually branches to depends on what it can prove. Where the receiver might
be `nil` it calls `-[Cache lookup]D_thunk` — a `linkonce_odr` thunk the *calling* translation
unit emits for itself, which performs the `nil` check and tail-calls the implementation.
Where the receiver is provably non-`nil`, it calls `-[Cache lookup]D` directly and no thunk
is emitted. Either way the Swift module defines exactly one symbol, `-[Cache lookup]D`; see
*Background* for why the preconditions live on the caller's side.

**`@objcDirect` implies `@objc`.** Writing it on a method that is not already exposed adds
the exposure.

**What you give up** is everything that reaches a method through the runtime: `#selector`,
`AnyObject` dynamic lookup, `@objc` protocol conformance, key-value observing,
`perform(_:)`, and `respondsToSelector:`. The compiler rejects the cases it can see. The
ones it cannot are discussed under *Implications on adoption*.

## Detailed design

### Applicability

`@objcDirect` may be written on a **method**, including a `static` method, or on an
**initializer**. A `class` method qualifies only where it is `final`, since rule 7 below
applies to it like any other overridable method.

It is rejected on any other declaration. In particular the attribute is not accepted on a
property, an accessor, or a subscript; see *Future directions*. It is accepted syntactically
on a `deinit` only so that the resulting error can name the problem specifically.

Within that set, the attribute is rejected on a declaration that, checked in this order:

1. is a `deinit`;
2. is a protocol requirement;
3. is not a member of a class — a global function, or a member of a struct or enum, has no
   printed `@interface` name to mangle against;
4. is in a generic class — generic classes are not printed to the generated header, so a
   direct symbol on one would be unreachable from Objective-C;
5. is `dynamic`, including implicitly via `@NSManaged` or `-enable-implicit-dynamic`;
6. is `@IBAction` or `@IBSegueAction` — these are wired up by selector from a nib or
   storyboard, which the compiler never sees;
7. is not `final` (initializers excepted) — an overridable method needs dynamic dispatch;
8. is a `required init`, which must be inherited;
9. is an `override`;
10. is `private` or `fileprivate`;
11. is `async` — there is no direct calling convention for an async method.

Each rejection is a compile-time error. The order is observable: `dynamic` is checked before
`final`, so `@objcDirect dynamic func` reports the `dynamic` conflict rather than the
missing `final`.

Two rules are load-bearing in a way that may not be obvious. `dynamic` is tested
semantically rather than as an attribute, so it also covers `@NSManaged` and
`-enable-implicit-dynamic`. The access-level rule uses the *declared* access of the method;
the *effective* access, capped by the enclosing context, is what determines visibility, and
that is a separate question covered below.

Only one of these is subtle. `dynamic` is checked before `final`, so a method that is both
non-`final` and `dynamic` reports the `dynamic` conflict — the accurate one, since `final`
would not have made it eligible:

```swift
class C: NSObject {
  @objcDirect dynamic func m() {}
  // error: '@objcDirect' cannot be applied to a 'dynamic' method; 'dynamic'
  //        requires dispatch through the Objective-C runtime
}
```

### What composes

* **Type methods.** A `static` method may be direct, as may a `final` `class` method. It
  mangles with `+` rather than `-`, matching clang.
* **`@objc(customName)`.** A method-level rename composes with `@objcDirect`: the renamed
  selector is what appears in the symbol and in the generated header, so the rename flows
  through end to end. A class-level `@objc(CustomName)` likewise supplies the class-name
  segment of the symbol.
* **Extension members.** A direct method may be declared in an extension of an eligible
  class.
* **`throws`.** A throwing direct method bridges to Objective-C the usual way, with a
  trailing `NSError **` parameter. It still takes no `_cmd`.
* **Implicit `final`.** Every member of a `final class` is already final, so the `final`
  rule is satisfied without writing it.

```swift
@objc(CustomName) public class Widget: NSObject {
  @objcDirect public final func instanceMethod() {}
  @objcDirect public static func typeMethod() {}
  @objc(renamedSelector) @objcDirect public final func originalName() {}
  @objcDirect public final func mayFail(cond: Int) throws -> Widget { self }
}

extension Widget {
  @objcDirect public final func inExtension() {}
}

final class AlreadyFinal: NSObject {
  @objcDirect func noExplicitFinalNeeded() {}
}
```

Writing `@objc` alongside is optional, since `@objcDirect` implies it. The implication is
*validated* rather than silently applied, so a signature Objective-C cannot represent — a
struct parameter, a tuple result — is still rejected, by the ordinary `@objc` diagnostics
rather than by a rule of this proposal.

### Symbol name and calling convention

A direct method is emitted under the Objective-C method name clang uses to reference it, so
that a clang caller and the Swift definition agree byte for byte. The implementation does
not take `_cmd`.

```swift
@objc class Foo: NSObject {
  @objcDirect final  func bar() {}
  @objcDirect static func classMethod() {}
  @objcDirect final  func aPlusB(int: Int, b: Int) -> Int { int + b }

  @objc       final  func normalMethod() {}   // for contrast
}
```

```llvm
define hidden void @"-[Foo bar]D"(ptr %0)
define hidden void @"+[Foo classMethod]D"(ptr %0)
define hidden i64  @"-[Foo aPlusBWithInt:b:]D"(ptr %0, i64 %1, i64 %2)

; the non-direct @objc method keeps its selector thunk, and that one takes _cmd:
define internal void @"$s…12normalMethodyyFTo"(ptr %0, ptr %1)
```

Three things are visible there. The direct entry points take `self` and the formal
arguments only — the second `ptr` that `normalMethod`'s thunk carries is `_cmd`, and a
direct method has no selector to pass. Class methods mangle with `+` rather than `-`. And
the `D` suffix is clang's direct-ABI marker, so the name matches what a clang caller emits.

The class-name segment is the **printed `@interface` name** — the `@objc(Name)` custom name
if there is one, otherwise the Swift class name. It is deliberately *not* the Objective-C
runtime name, which is the mangled `_TtC…` form: an Objective-C caller builds its reference
from the name in the header, so emitting the runtime name would produce a symbol nothing can
link against. This is the single design decision most likely to be got wrong in a
reimplementation.

```swift
@objc public class PlainClass: NSObject {
  @objc(renamedSelector) @objcDirect public final func originalName() {}
}
@objc(CustomName) public class Renamed: NSObject {
  @objcDirect public final func ping() {}
}
```

```llvm
define void @"-[PlainClass renamedSelector]D"(ptr %0)   ; method-level rename
define void @"-[CustomName ping]D"(ptr %0)              ; class-level rename
```

Overloaded initializers mangle apart by selector, and a `throws` method picks up the usual
trailing `NSError **` — still with no `_cmd`:

```llvm
define hidden ptr @"-[Inits initWithValue:]D"(ptr %0, i64 %1)
define hidden ptr @"-[Inits initWithName:]D"(ptr %0, ptr %1)
define hidden ptr @"-[Inits initWithX:y:]D"(ptr %0, i64 %1, i64 %2)

define        ptr @"-[Throwing throwableWithCond:error:]D"(ptr %0, i64 %1, ptr %2)
```

### Visibility and the generated header

Visibility follows Swift's access level, capped by context: a method whose *effective*
access is public gets default visibility; anything else is hidden and remains eligible for
dead-code elimination. Using effective rather than declared access matters — a `public`
method of an `internal` class is not reachable outside the module and should not be
exported.

```swift
@objc public class Visibility: NSObject {
  @objcDirect public  final func publicDirect()   {}
  @objcDirect         final func internalDirect() {}
  @objcDirect package final func packageDirect()  {}
}
```

```llvm
define        void @"-[Visibility publicDirect]D"(ptr %0)
define hidden void @"-[Visibility internalDirect]D"(ptr %0)
define hidden void @"-[Visibility packageDirect]D"(ptr %0)
```

At `-O` nothing takes the address of the two hidden symbols, so the linker can strip them if
nothing calls them. That is load-bearing for the size result: pinning them in `llvm.used`
would quietly forfeit the saving.

A non-public direct method is nevertheless still printed into the generated Objective-C
header when the module is not externally consumed, because the header for such a module is
generated at `internal` rather than `public` access. That is what makes the recommended
case — a direct method called only from Objective-C inside the same dynamic library —
reachable at all: the Objective-C caller sees the declaration, and the symbol it resolves to
is hidden and therefore carries no export cost.

The header annotates only the direct methods, through a macro the preamble guards on
`__has_attribute`, so the generated header remains usable with a compiler that does not know
`objc_direct`:

```objc
# if __has_attribute(objc_direct)
#  define SWIFT_OBJC_DIRECT __attribute__((objc_direct))
# else
#  define SWIFT_OBJC_DIRECT
# endif

@interface DirectMethodClass
- (NSInteger)directMethod SWIFT_WARN_UNUSED_RESULT SWIFT_OBJC_DIRECT;
- (void)normalMethod;
@end
```

### Rejecting dispatch that cannot work

A direct method is absent from its class's method list, so any construct that finds it by
selector at runtime would fail. The compiler rejects, at compile time:

* `#selector` referring to a direct method. The same check covers the `getter:` and
  `setter:` forms, which can only name a property imported from Objective-C, since the
  attribute is not accepted on a Swift property;
* `AnyObject` dynamic lookup — direct methods are excluded from the candidate set, so the
  call fails to type-check at the use site. This matches the existing treatment of
  Objective-C `objc_direct` methods imported into Swift. There is a known limitation: if
  some *other* visible type has a non-direct method of the same name and signature, that
  candidate is found instead and the call compiles; sending it to an instance of the direct
  class then fails at runtime. That is the ambient hazard of `AnyObject` dispatch rather
  than one this attribute introduces;
* a direct method as a witness to an `@objc` protocol requirement. The declaration itself is
  accepted; the *conformance* is invalidated, because that is where the problem is;
* `dynamic` and `@IBAction`, per *Applicability* above.

The `AnyObject` case is worth separating from the others: a direct method is *excluded from
the candidate set* rather than diagnosed, so the failure is the ordinary "no member" error at
the use site rather than a bespoke one. The `#selector` error, by contrast, carries an
explanatory note that attaches to the declaration rather than to the use site.

On the Objective-C side, clang already rejects sending to a direct method through a receiver
whose dynamic type is not statically known: an unqualified `id`, a `Class` value, and
`super`; it also rejects overriding one.

**One route is known not to be covered.** A protocol-qualified receiver — `id<P>` or
`Class<P>` — bypasses clang's check entirely:

```objc
@interface Direct
+ (int)clsDirect  __attribute__((objc_direct));
- (int)instDirect __attribute__((objc_direct));
@end

@protocol P          // a protocol can never declare a direct method
+ (int)clsDirect;
- (int)instDirect;
@end

int viaQualifiedClass(Class<P> c) { return [c clsDirect];  }  // no diagnostic
int viaQualifiedId(id<P> o)       { return [o instDirect]; }  // no diagnostic
```

There is no diagnostic, `-fsyntax-only` succeeds, and each call is emitted as an
`objc_msgSend` to a selector that has no method-list entry: an unrecognized-selector crash at
runtime, from code that compiled without a warning. We confirmed this with a compiled
reproducer against current upstream clang. The cause is that a protocol-qualified receiver is
resolved through the qualifying protocol, and a protocol can never declare a direct method,
so the guard that would fire never has a direct declaration in hand. It is a one-token
bypass — `id` is rejected, `id<P>` is not — and it is the change a developer is most likely
to reach for when a direct-method build error appears. This is a clang bug rather than
something this proposal introduces, and we will report it upstream separately; adopters
should know it is there.

With that exception, we are not aware of a statically visible route to selector dispatch
against a direct method that is not a compile-time error on one side or the other. We do
not claim that set is exhaustive: clang's receiver analysis has not been audited
systematically, and the first probe of it found the hole described above.

### Serialization and module interfaces

`@objcDirect` is serialized in binary `.swiftmodule` files and printed into textual
`.swiftinterface` files.

Printing it into an interface requires care. The attribute is only legal when the feature is
enabled, so an interface that carries `@objcDirect` must also record that fact, or rebuilding
the module from its own interface fails. Because `-enable-experimental-feature` is recorded
in `swift-module-flags`, the interface is self-describing and rebuilds correctly.

```swift
// Mod.swift
@objc public class Cache: NSObject {
  @objcDirect public final func lookup() {}
}
```

```swift
// Mod.swiftinterface
// swift-module-flags: -module-name Mod … -enable-experimental-feature ObjCDirect
@objc public class Cache : ObjectiveC.NSObject {
  @objcDirect public final func lookup()
}
```

The flag in the header is what legalizes the attribute in the body, so rebuilding the module
from this interface needs nothing on the command line. Note what is *absent*: the clang
option is not recorded, because enabling the Swift feature re-derives it.

Excluding the attribute from interfaces would also make them rebuildable, but
`-emit-objc-header` run against a module rebuilt from such an interface would drop
`SWIFT_OBJC_DIRECT`, and an Objective-C caller would then send a message to a selector the
method deliberately does not have — an unrecognized selector at runtime, replacing a link
error. Printing the attribute *and* recording the flag that legalizes it is the coherent
pair.

### Controlling export

A direct call across an image boundary needs an exported symbol, and that export is what
makes the cross-library case a regression rather than a saving. Hidden visibility was not
incidental to the 2019 Objective-C design; it was a stated rule, with an explicit C wrapper
as the sanctioned way to cross an image. So the question of who decides whether a direct
method is exported has to be answered, not inherited.

**Export follows the access level.** A method whose effective access is public is exported;
anything else is hidden and stays eligible for dead-code elimination. This is the same rule
Swift already uses for every other declaration, so it needs no new spelling and introduces
no second notion of visibility.

It also makes the case worth having reachable today. The configuration the measurements
favour — a direct method called from Objective-C inside the same image — is expressed by
declaring it `internal`. The symbol is hidden, and, because the generated header for a
module that is not externally consumed is emitted at `internal` access, the Objective-C
caller still sees the declaration. The saving is available without new syntax; the adopter
writes `internal` instead of `public`, which is what they meant.

The alternative is to **put the export decision in the attribute**, so that directness and
visibility are independent as they are in Objective-C, and a `public` method could be direct
without being exported. We did not adopt it, for three reasons.

1. It duplicates access control. Swift already has one answer to "is this visible outside the
   module," and a per-attribute knob is a second one that can disagree with the first. Two
   mechanisms governing one property is a cost paid by every reader of the code, not just by
   adopters of this attribute.
2. It would be the only attribute in Swift that overrides access-derived linkage. That is a
   large precedent to set from a narrow interop feature, and it would invite the same knob on
   everything else that emits a symbol.
3. The residual gap is smaller than it first looks. Because `internal` already covers the
   recommended case, what is left is specifically a method that must be `public` for Swift
   clients while its *Objective-C* symbol is only ever called in-image. That is a real
   situation, but it reads more like a missing access level — "visible to Objective-C within
   this image" — than like a parameter on this attribute, and designing an access level is
   not something this proposal should do on the side.

We would rather be argued out of this than guess. If there is a spelling that gives the
residual case what it needs without creating a second visibility mechanism, we would adopt
it; this is the part of the design we hold most loosely.

## Source compatibility

Writing `@objcDirect` requires the experimental feature flag, so no existing spelling
changes meaning by acquiring the attribute.

Two of the new checks are **not** gated on that flag, and can therefore affect existing
code. They test whether a declaration is direct-dispatched, which is also true of an
Objective-C `objc_direct` method imported into Swift. With the feature disabled, and in
code that never writes the attribute:

* `#selector` naming an imported direct method is now an error. It previously compiled and
  produced a selector the class does not respond to. This covers the `getter:` and `setter:`
  forms naming an imported direct property.
* An imported direct method witnessing an `@objc` protocol requirement now invalidates the
  conformance. It was previously accepted, and every call made through the protocol would
  have failed at runtime.

Each of these replaces a runtime failure with a compile-time one, which is the point. But
code that imports Objective-C direct methods can stop building, and this section should not
be read as "no impact."

## ABI compatibility

Adding or removing `@objcDirect` on a method **changes that method's Objective-C ABI**. The
symbol name changes, the method leaves or rejoins the class method list, and the calling
convention changes from message send to direct call. Objective-C callers must be
recompiled.

The attribute is therefore ABI-breaking to add and to remove on a method that Objective-C
code outside the module calls. It has no effect on the Swift ABI of the same method: the
native Swift entry point is unchanged, and Swift callers continue to use it.

The proposal does not change code generation for any declaration that does not carry the
attribute.

## Implications on adoption

**This feature requires a toolchain whose clang supports the direct-method precondition
thunk ABI** (`-fobjc-direct-precondition-thunk`). The flag itself exists in clang 22, but the
thunk generation that gives it meaning landed for clang 23, so clang 23 is the real floor —
on 22 the flag parses and changes the symbol name without producing the caller-side thunk.
The Swift attribute is gated on the feature as a whole. This is also why the implementation
is based on `rebranch` rather than `main`: `main` currently pairs with an LLVM that predates
the ABI.

**Every Objective-C translation unit that imports the generated header must be built with
the same flag.** A mismatch is a link error — the symbol loses its suffix and does not
resolve. This fails loudly rather than silently, which is the intended behavior, but it
makes the flag a build-system-wide setting in practice rather than a per-target one.

That flag has been running in production in large applications for some time, and clang's
own driver records the intent for it to become the default. Once it is, this constraint
disappears and `@objcDirect` could be enabled by default in Swift as well.

**`@objcDirect` is a contract.** The developer is asserting that the method will not be
dispatched dynamically. The compiler enforces what it can see; four things it cannot:

* **`respondsToSelector:`** returns `false` for a direct method. This is the only failure
  mode in the set that is silent in both directions — a feature-detection branch simply
  takes the other path. It is worth auditing for before adopting.
* **Runtime-constructed selectors** — `NSSelectorFromString`, `perform(_:)`, key-value
  coding. Inherently undecidable statically.
* **Protocol-qualified Objective-C receivers**, per *Rejecting dispatch that cannot work*:
  clang does not currently diagnose these, and the call becomes an unrecognized selector at
  runtime.
* **Test doubles that stub by selector** will stop intercepting. This fails in test runs
  rather than in production, which is the good outcome.

**Adoption is reversible in source** with no Swift-side consequences, but reversing it is
an Objective-C ABI change as described above.

### Measured impact

The size effect is conditional: it depends on where the callers are, and on the shape of
the receiver at each call site. Both conditions are quantified below.

**How the numbers below were obtained.** Every figure is a section-level delta on a linked
Mach-O image, including `__LINKEDIT`, at `-Os`, for the triple
`arm64-apple-ios17.0-simulator`. The link-level figures come from a bench of 25 methods
across two classes using realistic selector names (mean length 56 B); the per-method
metadata coefficients were measured separately on a larger single-class bench, and the
method-list coefficient was confirmed against it. Three qualifications travel with all of
it:

* **The bench is Objective-C, not Swift.** The metadata removal is identical either way,
  but it does not model Swift's native-to-foreign ARC thunk, which `@objcDirect` *retains*
  — a Swift adopter keeps that thunk, and the numbers here do not price it.
* **Every direct method in the bench was exported.** Clang's default is the opposite: a
  direct method is hidden unless the source asks otherwise. Exporting them all is the
  conservative direction, and the gap is measurable: the export trie costs about 14.7 B per
  method even when every caller is in the same image, so dropping it takes the same-library
  figure from −64 B to roughly −79 B. A non-exported direct method — the `internal` case
  this proposal recommends, which Swift emits as a hidden symbol — starts there.
* **25 methods across two classes is a small population.** It is enough to exercise
  symbol-name prefix compression, but not enough to predict how it behaves across
  thousands of methods on hundreds of classes. This matters most for the cross-library
  figure, noted again below.

**The metadata half is corroborated on real code.** Annotating 25 methods on one large
social application and building it feature-on against baseline reproduced the method-list
coefficient at 24.00 B per method, against 24.04 B from the synthetic bench — three
independent measurements agreeing to within 0.2%. Selector-string removal was confirmed the
same way, with sibling plain-`@objc` selectors left in place as controls to prove the
extraction was measuring what it claimed.

That surface is silent on everything else, and deliberately so: it has no Objective-C
callers, so its `__objc_selrefs` and `__text` deltas were both exactly zero. The call-site
and export figures below therefore rest on the bench alone, and the caveats above apply to
them in full.

**Metadata removed** — consistent, and the reason to do this at all:

| | per method |
|---|---|
| Method-list entry | −12 B in the linked image, −24 B in the object file; the linker rewrites it to the 12-byte relative form |
| Selector string in `__objc_methname` | −0 B if another user of that selector keeps it alive, otherwise the length of the string; the selectors measured averaged 57 B, with a minimum of 18 and a maximum of 98 |
| `__objc_selrefs` slot | −8 B, one pointer slot, when the image no longer references that selector anywhere; 0 if another call site keeps it alive |

**Whether that nets out as a win depends on where the callers are:**

Two benches bracket this, differing only in call-site density. They are not endpoints of a
confidence interval, and the two rows are not independent — each column is one bench, and the
figures move inversely because both depend on the same variable:

| per method | one call per selector | call density amortized |
|---|---|---|
| Caller in the same dynamic library | −102 B | **−64 B** (a saving) |
| Caller in a different dynamic library | +37 B | **+91 B** (a *regression*) |

Real code sits between the columns, closer to the amortized one as call density rises. The
bolded column is what the summary quotes: it is the same bench for both rows, and it is the
pessimistic pair — the smaller saving alongside the larger loss. Mixing columns, by taking
−64 B together with +37 B or by averaging across them, would describe no bench that was run.

The cross-library magnitude is **direction-solid and magnitude-indicative**. The sign
survived every methodology correction, but export-trie cost depends on prefix sharing across
the whole symbol set, and this bench is too small to pin the magnitude.

The cross-library case regresses because a direct call needs an exported symbol. The
defining library gains an export-trie entry and every calling library gains an import: a
symbol string, a chained-fixup entry, a symbol-table entry, and a stub or GOT slot. In
exchange it gives up one *shared* `objc_msgSend` import and a selector reference. That
trade does not pay.

It is worth being precise about whose decision that is. Objective-C gives a direct method
hidden visibility by default. This implementation exports every direct method whose
effective access is public, and it is the export, not the direct dispatch, that creates
the cost. The regression is a consequence of a choice in this design, discussed under
*Controlling export*.

**Call sites vary by receiver, and one case is free:**

| Receiver | per call site |
|---|---|
| `self` | **0** — byte-identical, a 4-byte branch either way |
| A value that may be `nil` | positive, single-digit to low-teens bytes (+4, +14 and +7 B measured at one, five and twenty call sites) |
| A class method | **~+17 B** (measured at twenty call sites; higher with fewer) |

Class methods are the expensive case. A class must be realized before a method on it can
be dispatched, and a direct call has no `objc_msgSend` to do that, so clang emits the
realization into the method's shared caller-side thunk — one `linkonce_odr` thunk per
method per image. At `-Os` that thunk inlines into its callers, so in practice the cost is
paid per call site. Fitting the measurements gives roughly a fixed ~16 B per method plus
~16 B per call site — the fixed term is the uniqued `"self"` selector reference and its
name, which are per image rather than per site. The measured per-site average was +16.8 B
at twenty call sites, and is higher when a method has only one or two.

**Guidance.** `@objcDirect` pays off on methods called from within the same dynamic
library, and most clearly on instance methods reached through `self`. It can cost more
than it saves on methods called across a library boundary, and on class methods called
from many sites. Adopters with a whole-program view can distinguish these; adopters
without one should expect to measure.

Whole-program analysis across four large applications identified roughly 29,300 methods
satisfying an approximation of the eligibility rules below — the analyzer's rules are
close to, but not identical with, what the compiler enforces. The implementation has been
exercised end to end on the build graphs of two of them. Actual adoption to date is a
small pilot: what is being reported here is a measured per-method coefficient and a
population, not a shipped result.

## Future directions

### An attribute for all members of a class

Objective-C has `objc_direct_members`, and the 2023 pitch proposed a Swift analogue
alongside the per-method attribute. A class-level spelling would avoid repeating the
attribute on every member and would compose naturally with `@objcMembers`.

This proposal deliberately covers only the per-method attribute. Methods are where the
measured benefit is concentrated, and a class-level attribute raises questions the
per-method form does not — in particular how it would interact with the applicability rules
above, since a class will typically contain members that cannot be direct. Settling the
per-method semantics first gives that design something concrete to build on.

### Properties, accessors, and subscripts

Objective-C supports `@property (direct)`. This proposal does not include property
accessors or subscripts; the attribute is rejected on them.

The reason is the shape of the failure, not the size of the work. A direct entry point does
not take `_cmd`, but an accessor's selector is registered in the class's method list through
its *storage* declaration, on a path that never consults the attribute — the method-emission
path that would consult it returns on seeing an accessor before reaching the check. A
selector-dispatched call would then land on an entry point whose argument registers are
shifted by one. Unlike every other route this proposal closes, that corrupts rather than
traps: a nullary getter is benign by accident, since it reads only the receiver register,
while a setter or a subscript takes the selector pointer in its first real argument slot and
stores it where a value belongs. Rejecting the attribute on accessors keeps that shape
unreachable until the registration path consults it.

### Interaction with `@implementation`

[SE-0436][se0436] lists `objc_direct` methods and `direct` properties among the declarations
`@implementation` cannot currently express. If both features are in the language, the
interaction would have to be defined: `ObjCImplementationChecker` would need to require that
the directness of the declaration and of the implementation agree, and diagnose a mismatch.
Code generation does not appear to need a change.

[se0436]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0436-objc-implementation.md
