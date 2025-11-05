# Module selectors for name disambiguation

* Proposal: [SE-0491](0491-module-selectors.md)
* Authors: [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: [Freddy Kellison-Linn](https)
* Status: **Accepted**
* Bug: [swiftlang/swift#53580](https://github.com/swiftlang/swift/issues/53580) (SR-11183)
* Implementation: [swiftlang/swift#34556](https://github.com/swiftlang/swift/pull/34556)
* Review: ([pitch](https://forums.swift.org/t/pitch-module-selectors/80835)) ([review](https://forums.swift.org/t/se-0491-module-selectors-for-name-disambiguation/82124)) ([acceptance](https://forums.swift.org/t/accepted-se-0491-module-selectors-for-name-disambiguation/82589))

Previously pitched in:

* [Pitch: Fully qualified name syntax](https://forums.swift.org/t/pitch-fully-qualified-name-syntax/28482)

## Introduction

We propose that Swift's grammar be extended so that, wherever an identifier
is written in source code to reference a declaration, it can be prefixed by
`ModuleName::` to disambiguate which module the declaration is expected to
come from. This syntax will provide a way to resolve several types of name
ambiguities and conflicts.

## Motivation

Swift's name lookup rules promote its goal of allowing code to be written in a
very clean, readable style. However, in some circumstances it can be very
difficult to unambiguously reference the declaration you want.

### Background

When Swift looks up a name in your source code to find the declaration it
refers to, that lookup can be either *qualified* or *unqualified*. Qualified
lookups are restricted to looking inside a certain declaration, while
unqualified lookups search more broadly. For example, in a chain of names such
as:

```swift
mission().booster().launch()
```

`booster()` can only refer to members of whatever type is returned by
`mission()`, and `launch()` can only refer to members of whatever type is
returned by `booster()`, so Swift will find them using a qualified lookup.
`mission()`, on the other hand, does not have to be a member of some specific
type, so Swift will find that declaration using an unqualified lookup.

> **Note**: Although the examples given here mostly concern uses in
> expressions, qualified and unqualified lookups are also used for names in
> type syntax, such as `Mission.Booster.Launch`. The exact lookup rules are
> slightly different but the principles are the same.

Both kinds of lookups are slightly sensitive to context in that, since the
acceptance of [SE-0444 Member Import Visibility][SE-0444],
they are both limited to declarations imported in the current source file;
however, unqualified lookups take *much* more than just that into account. They
search through any enclosing scopes to find the "closest" use of that name. For
example, in code like:

```swift
import RocketEngine
import IonThruster

extension Mission {
    struct Booster {
        func launch(_ crew: Int) {
            let attempt = 1
            ignite()
        }
    }
}
```

Swift will look for `ignite` in the following places:

1. The local declarations inside `launch(_:)`
2. The parameters to `launch(_:)`
3. Instance members and generic parameters of the enclosing type `Booster`
   (including its extensions, superclasses, conformances, etc.)
4. Static members and generic parameters of the enclosing type `Mission`
5. Top-level declarations in this module
6. Top-level declarations in other imported modules
7. The names of imported modules

These rules are a little complicated when written out like this, but their
effect is pretty simple: Swift finds whichever `ignite` is in the "closest"
scope to the use site. If both `Booster` and `Mission` have an `ignite`, for
example, Swift will use the one in `Booster` and ignore the one in `Mission`.

Of particular note is the last place Swift looks: the names of imported
modules. This is intended to help with situations where two modules have
declarations with the same name. For example, if both `RocketEngine` and
`IonThruster` declare an `ignite()`, `RocketEngine.ignite()` will find `ignite`
using a qualified lookup inside the module `RocketEngine`, filtering out the
one in `IonThruster`. This works in simple cases, but it breaks down in a
number of complicated ones.

### Unqualified lookups are prone to shadowing

Swift does not prevent declarations in different scopes from having the same
name. For example, there's nothing preventing you from having both a top-level
type and a nested type with the same name:

```swift
struct Scrubber { ... }

struct LifeSupport {
    struct Scrubber { ... }
}
```

This means that the same name can have different meanings in different places:

```swift
// This returns the top-level `Scrubber`:
func makeScrubber() -> Scrubber { ... }

extension LifeSupport {
    // This returns `LifeSupport.Scrubber`:
    func makeScrubber() -> Scrubber { ... }
}
```

Specifically, we say that within the extension, `LifeSupport.Scrubber`
*shadows* the top-level `Scrubber`.

This poses certain challenges—especially for mechanically-generated code, such
as module interface files—but it's usually not completely insurmountable
because you can qualify a top-level declaration with its module name. However,
it becomes a problem if *the module name itself* is shadowed by a type with the
same name:

```swift
// Module RocketEngine
public struct RocketEngine { ... }
public struct Fuel { ... }

// Another module
import RocketEngine

_ = RocketEngine.Fuel()    // Oops, this is looking for a nested type in the
                           // struct RocketEngine.RocketEngine!
```

In this situation, we can no longer qualify top-level declarations with module
names. That makes code generation *really* complicated, because there is no
syntax that works reliably—qualifying will help with some failures but cause
others.

That may sound like a farfetched edge case, but it's surprisingly common for a
module to contain a type with the same name. For instance, the `XCTest` module
includes an `XCTest` class, which is a base class for `XCTestCase` and
`XCTestSuite`. To avoid this kind of trouble, developers must be careful to
give modules different names from the types inside them—the `Observation`
module, for example, might have been called `Observable` if it didn't have a
type with that name.

### Qualified lookups can be unresolvably ambiguous 

Extensions create the possibility that a type may have two members with the
same name and similar or even outright conflicting overload signatures,
distinguished only by being in different modules. This is not a problem for
Swift's ABI because the mangled name of an extension member includes the
module it was declared in; however, there is no way to add a module name to
an already-qualified non-top-level lookup, so there's no way to express this
distinction in the surface language. Developers' only option may be to fiddle
with their imports in an attempt to make sure the desired member is the only
one that's visible.

### Macros don't support module qualification

Macros cannot have members--the grammar of a macro expansion allows only a
single identifier, and any subsequent `.` is taken to be a member lookup on
the expansion--so there is currently no way to qualify a macro expansion with
a module name. This limitation was discussed during the [second review of SE-0382][SE-0382-review-2]
and the author suggested the only viable solution was to add a new,
grammatically-distinguishable syntax for module qualification.

### These problems afflict module interfaces, but aren't unique to them

These issues show up most often in module interfaces because the compiler
needs to generate syntax that reliably resolves to a specific declaration, but
the rules' sensitivity to context and module contents (which might change over
time!) makes that very difficult. In practice, the compiler does not attempt to
fully account for shadowing and name conflicts--by default it qualifies names
as fully as the language allows (which works about 95% of the time) and offers
a number of (undocumented) workaround flags to adjust that which are added by a
maintainer when they discover that their module is in the remaining 5%. These
flags aren't enabled automatically, though, and they don't affect the module
interfaces of downstream modules which need to reference affected declarations.
In short, the situation is a mess.

It's important to keep in mind, though, that this doesn't *just* affect module
interfaces and generated code. Code written by humans can also run into these
issues; it's just that a person will notice the build error and fiddle with
their code until they get something that works. It therefore makes sense to
introduce a new syntax that can be used by both machines and humans.

### Separate modules make this uniquely severe

While problematic conflicts can sometimes occur between two declarations in a
single module, the authors believe that per-module disambiguation is the right
approach because shadowing within a module is much easier to detect and
resolve. The developer will generally notice shadowing problems when they build
or test their code, and since they control both the declaration site and the
use site, they have options to resolve any problems that are not otherwise
available (like renaming declarations or tweaking their overload signatures).
The compiler also detects and prevents outright conflicts within a specific
module, such as two extensions declaring the exact same member, which it would
allow if the declarations were in different modules. 

## Proposed solution

We propose adding *module selectors* to the language. A module selector is
spelled `<ModuleName>::` and can be placed before an identifier to indicate
which module it is expected to come from:

```swift
_ = RocketEngine::Fuel()    // Picks up the `Fuel` in `RocketEngine`, bypassing
                            // any other `Fuel`s that might be in scope
```

On an unqualified lookup, a module selector also indicates that lookup should
start at the top level, skipping over the declarations in contextually-visible
scopes:

```swift
// In module NASA

struct Scrubber { ... }

struct LifeSupport {
    struct Scrubber { ... }
}

extension LifeSupport {
    // This returns the top-level `Scrubber`
    func makeMissionScrubber() -> NASA::Scrubber { ... }
}
```

Module selectors may also be placed on qualified lookups to indicate which
module an extension member should belong to:

```swift
// In module IonThruster
extension Spacecraft {
     public struct Engine { ... }
}

// In module RocketEngine
extension Spacecraft {
     public struct Engine { ... }
}

// In module NASA
import IonThruster
import RocketEngine

func makeIonThruster() -> Spacecraft.IonThruster::Engine { ... }
```

Module selectors are permitted at locations in the type and expression syntax
where a declaration from elsewhere is referenced by name. However, it is
invalid to use one on the name of a *new* declaration:

```swift
struct NASA::Scrubber {     // Invalid--new declarations are always in the current module
    ...
}
```

We chose this syntax—module name plus `::` operator prefixing the name they
qualify—because `::` is unused in Swift (it can't even be a custom operator)
and because using `::` in this fashion is highly precedented in other
languages. (C++, PHP, Java, and Rust all use it to indicate that the name on
the right should be looked up inside the scope on the left; Ruby and Perl use
it *specifically* to look up declarations inside modules.)

## Detailed design

### Grammar and parsing

A module selector has the following grammar:

> *module-selector* → *identifier* `::`

The following productions may now optionally include a module selector (changes are in bold):

> *type-identifier* → ***module-selector?*** *type-name* *generic-argument-clause?* | ***module-selector?*** *type-name* *generic-argument-clause?* `.` *type-identifier*
> 
> *primary-expression* → ***module-selector?*** *identifier* *generic-argument-clause?*
>
> *implicit-member-expression* → `.` ***module-selector?*** *identifier*<br>  
> *implicit-member-expression* → `.` ***module-selector?*** *identifier* `.` *postfix-expression*
>
> *macro-expansion-expression* → `#` ***module-selector?*** *identifier* *generic-argument-clause?* *function-call-argument-clause?* *trailing-closures?*
>
> *key-path-component* → ***module-selector?*** *identifier* *key-path-postfixes?* | *key-path-postfixes*
> 
> *function-call-argument* → ***module-selector?*** *operator* | *identifier* `:` ***module-selector?*** *operator*
>
> *initializer-expression* → *postfix-expression* `.` ***module-selector?*** `init`<br>
> *initializer-expression* → *postfix-expression* `.` ***module-selector?*** `init` `(` *argument-names* `)`
>
> *explicit-member-expression* → *postfix-expression* `.` ***module-selector?*** *identifier* *generic-argument-clause?*<br>
> *explicit-member-expression* → *postfix-expression* `.` ***module-selector?*** *identifier* `(` *argument-names* `)`
>
> *attribute-name* → ***module-selector?*** *identifier*
>
> *enum-case-pattern* → *type-identifier?* `.` ***module-selector?*** *enum-case-name* *tuple-pattern?*

Additionally, a new production allows a scoped `import` declaration to use a
module selector and identifier instead of an import path:

> *import-declaration* → *attributes?* `import` *import-kind?* *import-path*<br>
> ***import-declaration* → *attributes?* `import` *import-kind* *module-selector* *identifier***

Note that this new *import-declaration* production does not allow a submodule
to be specified. Use the old `.`-operator-based syntax for submodules.

#### Token-level behavior

The `::` operator may be separated from its *identifier* by any whitespace,
including newlines. However, the `::` operator must *not* be separated from the 
token after it by a newline:

```swift
NationalAeronauticsAndSpaceAdministration::
  RocketEngine      // Invalid
NationalAeronauticsAndSpaceAdministration
  ::RocketEngine    // OK
```

> **Note**: This restriction aids in recovery when parsing incomplete code;
> the member-lookup `.` operator follows a similar rule.

If the token after the `::` operator is a keyword, it will be treated as an
ordinary identifier unless it would have special meaning:

```swift
print(default)          // Invalid; 'default' is a keyword and needs backticks
print(NASA.default)     // OK under SE-0071
print(NASA::default)    // OK under this proposal
```

Depending on context, the following keywords may still be treated as special in
expressions:

* `deinit`
* `init`
* `subscript`

> **Note**: This behavior is analogous to [SE-0071 Allow (most) keywords in member references][SE-0071].

Similarly, attributes that use a module selector will always be treated as
custom attributes, not built-in attributes. (Put another way, built-in
attributes do not belong to *any* module—not even `Swift`.) Like all custom
attributes, any arguments must be valid expressions.

```swift
@Swift::available(macOS 15.0.1, *)    // Invalid; not parsed as the built-in `@available`
class X {}
```

#### Patterns

Module selectors are allowed in *enum-case-pattern* and in *type* and
*expression* productions nested inside patterns. However, *identifier-pattern*
is unmodified and does *not* permit a module selector, even in shorthand
syntaxes designed to declare a shadow of an existing variable. If a module 
selector is needed, you must use an explicit initializer expression.

```swift
if let NASA::rocket { ... }                // Invalid
if let rocket = NASA::rocket { ... }       // OK

Task { [NASA::rocket] in ... }             // Invalid
Task { [rocket = NASA::rocket] in ... }    // OK
```

#### Operator and precedence group declarations

The *precedence-group-name* production is unmodified and does not permit
a module selector. Precedence group names exist in a separate namespace from
other identifiers and no need for this feature has been demonstrated.

#### Parsed declaration names

A parsed declaration name, such as the name in an `@available(renamed:)`
argument, may use module selectors on the declaration's base name and context
names.

```swift
@available(*, deprecated, renamed: "NASA::launch(_:from:)")    // OK
public func launch(_ mission: Mission) {
  launch(mission, from: LaunchPad.default)
}
```

Module selectors are not valid on base names in clang `swift_name` and
`swift_async_name` attributes, since these specify the name of the current
declaration, rather than referencing a different declaration.

> **Note**: Clang Importer currently cannot apply import-as-member `swift_name`
> or `swift_async_name` attributes that name a context in a different module,
> but if this limitation is ever lifted, module selectors ought to be supported
> on context names in these clang attributes.

#### Syntaxes reserved for future directions

It is never valid to write two module selectors in a row; if you want to access
a declaration which belongs to a clang submodule, you should just write the
top-level module name in the module selector.

It is never valid to write a keyword, operator, or `_` in place of a module
name; if a module's name would be mistaken for one of these, it must be
wrapped in backticks to form an identifier.

### Effects on lookup

When a reference to a declaration is prefixed by a module selector, only
declarations declared in, or re-exported by, the indicated module will be
considered as candidates. All other declarations will be filtered out.

For example, in the following macOS code:

```swift
import Foundation

class NSString {}

func fn(string: Foundation::NSString) {}
```

`string` will be of type `Foundation.NSString`, rather than the `NSString`
class declared in the same file. Because the AppKit module
re-exports Foundation, this example would also behave the same way:

```swift
import AppKit

class NSString {}

func fn(string: AppKit::NSString) {}
``` 

> **Note**: Allowing re-exports ensures that "hoisting" a type from its
> original module up to another module it imports is not a source-breaking
> change. It also helps with situations where developers don't realize where a
> given type is declared; for instance, many developers believe `NSObject` is
> declared in `Foundation`, not `ObjectiveC`.

Additionally, when a reference to a declaration prefixed by a module selector
is used for an unqualified lookup, the lookup will begin at the module-level
scope, skipping any intervening enclosing scopes. That means a top-level
declaration will not be shadowed by local variables, parameters, generic
parameters, or members of enclosing types:

```swift
// In module MyModule

class Shadowed {
    struct Shadowed<Shadowed> {
        let Shadowed = 42
        func Shadowed(Shadowed: () -> Void) {
            let Shadowed = "str"
            let x = MyModule::Shadowed()    // refers to top-level `class Shadowed`
        }
    }
}
```

A module selector can only rule out declarations that might otherwise have been
chosen instead of the desired declaration; it cannot access a declaration which
some other language feature has ruled out. For example, if a declaration is
inaccessible because of access control or hasn't been imported into the current
source file, a module selector will not allow it to be accessed.

#### Member types of type parameters

A member type of a type parameter must not be qualified by a module selector.

```swift
func fn<T: Identifiable>(_: T) where T.Swift::ID == Int {    // not allowed
    ...
}
```

This is because, when a generic parameter conforms to two protocols that have
associated types with the same name, the member type actually refers to *both*
of those associated types. It doesn't make sense to use a module name to select
one associated type or the other--it will always encompass both of them.

(In some cases, a type parameter's member type might end up referring to a 
concrete type—typically a typealias in a protocol extension–which
theoretically *could* be disambiguated in this way. However, in these
situations you could always use the protocol instead of the generic parameter
as the base (and apply a module selector to it if needed), so we've chosen not
to make an exception for them.)

## Source compatibility

This change is purely additive; it only affects the behavior of code which uses
the new `::` token. In the current language, this sequence can only appear
in valid Swift code in the selector of an `@objc` attribute, and the parser
has been modified to split the token when it is encountered there. 

## ABI compatibility

This change does not affect the ABI of existing code. The Swift compiler has
always resolved declarations to a specific module and then embedded that
information in the ABI's symbol names; this proposal gives developers new ways
to influence those resolution decisions but doesn't expand the ABI in any way.

## Implications on adoption

Older compilers will not be able to parse source code which uses module
selectors. This means package authors may need to increase their tools version
if they want to use the feature, and authors of inlinable code may need to
weigh backwards compatibility concerns.

Similarly, when a newer compiler emits module selectors into its module
interfaces, older compilers won't be able to understand those files. This isn't
a dealbreaker since Swift does not guarantee backwards compatibility for module
interfaces, but handling it will require careful staging and there may be a
period where ABI-stable module authors must opt in to emitting module 
interfaces that use the feature.

## Future directions

### Special syntax for the current module

We could allow a special token, or no token, to be used in place of the module
name to force a lookup to start at the top level, but not restrict it to a
specific module. Candidates include:

```swift
Self::ignite()
_::ignite()
*::ignite()
::ignite()
```

These syntaxes have all been intentionally kept invalid (a module named `Self`,
for instance, would have to be wrapped in backticks: `` `Self`::someName ``),
so one of them can be added later if there's demand for it.

### Disambiguation for subscripts

There is currently no way to add a module selector to a use of a subscript. We
could add support for a syntax like:

```swift
myArray.Swift::[myIndex]
```

### Disambiguation for conformances

Retroactive conformances have a similar problem to extension members—the ABI
distinguishes between otherwise identical conformances in different modules,
but the surface syntax has no way to resolve any ambiguity—so a feature which
addressed them might be nice. However, there is no visible syntax associated
with use of a conformance that can be qualified with a module selector, so it's
difficult to address as part of this proposal.

It's worth keeping in mind that [SE-0364's introduction of `@retroactive`][SE-0364]
reflects a judgment that retroactive conformances should be used with care. The
absence of such a feature is one of the complications `@retroactive` is meant
to flag.

### Support selecting conflicting protocol requirements

Suppose that a single type conforms to two protocols with conflicting protocol
requirements:

```swift
protocol Employable {
    /// Terminate `self`'s employment.
    func fire()
}

protocol Combustible {
    /// Immolate `self`.
    func fire()
}

struct Technician: Employable, Combustible { ... }
```

It'd be very useful to be able to unambiguously specify which protocol's
requirement you're trying to call:

```swift
if myTechnician.isGoofingOff {
    myTechnician.Employable::fire()
}
if myTechnician.isTooCloseToTheLaunch {
    myTechnician.Combustible::fire() 
}
```

However, allowing a protocol name—rather than a module name—to be written
before the `::` token re-introduces the same ambiguity this proposal seeks
to solve because a protocol name could accidentally shadow a module name.
We'll probably need a different feature with a distinct syntax to resolve
this use case—perhaps something like:

```swift
if myTechnician.isGoofingOff {
    (myTechnician as some Employable).fire()
}
```

### Support selecting default implementations

Similarly, it would be useful to be able to specify that you want to call a
default implementation of a protocol requirement even if the conformance
provides another witness. (This could be used similarly to how `super` is used
in overrides.) However, this runs into similar problems with reintroducing
ambiguity, and it also just doesn't quite fit the shape of the syntax (there's
no name to uniquely identify the default implementation you want). Once again,
this probably requires a different feature with a distinct syntax—perhaps
something a little more like how `super` works.

## Alternatives considered

### Change lookup rules in module interfaces

Some of the problems with module interfaces could be resolved by changing the
rules for qualified lookup *within module interface files specifically*. For
instance, we could decide that in a module interface file, unqualified lookups
can only find module names, and the compiler must always qualify every name
with a module name.

This would probably be a viable solution with enough effort, but it has a
number of challenges:

1. There are some declarations—generic parameters, for instance—which are
   not accessible through any qualified lookup (they are neither top-level
   declarations nor accessible through the member syntax). We would have to
   invent some way to reference these.

2. Existing module interfaces have already been produced which would be broken
   by this change, so it would have to somehow be made conditional.

3. Currently, inlinable function bodies are not comprehensively regenerated
   for module interfaces; instead, the original textual source code is
   inserted with minor programmatic edits to remove comments and `#if` blocks.
   This means we would have to revert to the normal lookup rules within an
   inlinable function body.

It also would not help with ambiguous *qualified* lookups, such as when two
modules use extensions to add identically-named nested types to a top-level
type, and it would not give developers new options for handling ambiguity in
human-written code.

### Add a fallback lookup rule for module name shadowing

The issue with shadowing of module names could be addressed by adding a narrow
rule saying that, when a type has the same name as its enclosing module and a
qualified lookup inside it doesn't find any viable candidates, Swift will fall
back to looking in the module it shadowed.

This would address the `XCTest.XCTestCase` problem, which is the most common
seen in practice, but it wouldn't help with more complicated situations (like
a nested type shadowing a top-level type, or a type in one module having the
same name as a different module). It's also not a very principled rule and
making it work properly in expressions might complicate the type checker. 

### Use a syntax involving a special prefix

We considered creating a special syntax which would indicate unambiguously that
the next name must be a module name, such as `#Modules.FooKit.bar`. However,
this would only have helped with top-level declarations, not members of
extensions.

### Use a syntax that avoids `::`'s shortcomings

Although we have good reasons to propose using the `::` operator (see "Proposed
solution" above), we do not think it's a perfect choice. It appears visually
"heavier" than the `.` operator, which means developers reading the code might
mentally group the identifiers incorrectly:

```swift
Mission.NASA::Booster.Exhaust    // Looks like it means `(Mission.NASA) :: (Booster.Exhaust)`
                                 //  but actually means `Mission . (NASA::Booster) . Exhaust` 
```

This is not unprecedented—in C++, `myObject.MyClass::myMember` means
`(myObject) . (MyClass::myMember)`—but it's awkward for developers without
a background in a language that works like this.

We rejected a number of alternatives that would avoid this problem.

#### Make module selectors qualify different names

One alternative would be to have the module selector qualify the *rightmost*
name in the member chain, rather than the leftmost, so that a module selector
could only appear at the head of a member chain. The previous example would
then be written as:

```swift
(NASA::Mission.Booster).Exhaust
```

We don't favor this design because we believe:

1. Developers more frequently need to qualify top-level names (which exist in a
   very crowded quasi-global namespace) than member names (which are already
   limited by the type they're looking inside); a syntax that makes qualifying
   the member the default is optimizing for the wrong case.

2. The distance between the module and the identifier it qualifies increases
   the cognitive burden of pairing up modules to the names they apply to.

3. Subjectively, it's just *weird* that the selector applies to a name that's a
   considerable distance from it, rather than the name immediately adjacent.

A closely related alternative would be to have the module selector qualify
*all* names in the member chain, so that in `(NASA::Mission.Booster).Exhaust`,
both `Mission` and `Booster` must be in module `NASA`. We think point #1 from
the list above applies to this design too: `Mission` is a sparse enough
namespace that developers are more likely to be hindered by `Booster` being
qualified by the `NASA` module than helped by it.

#### Use a totally different spelling

We've considered and rejected a number of other spellings for this feature,
such as:

```swift
Mission.#module(NASA).Booster.Exhaust    // Much wordier, not implementable as a macro
Mission.::NASA.Booster.Exhaust           // Looks weird in member position
Mission.Booster@NASA.Exhaust             // Ignores Swift's left-to-right nesting convention
Mission.'NASA.Booster.Exhaust            // Older compilers would mis-lex in inactive `#if` blocks
Mission.NASA'Booster.Exhaust             //           "
Mission.(NASA)Booster.Exhaust            // Arbitrary; little connection to prior art
Mission.'NASA'.Booster.Exhaust           //           "    
```

### Don't restrict whitespace to the right of the `::`

Allowing a newline between `::` and the identifier following it would mean
that, when an incomplete line of code ended with a module selector, Swift might
interpret a keyword on the next line as a variable name, likely causing multiple
confusing syntax errors in the next statement. For instance:

```swift
let x = NASA::    // Would be interpreted as `let x = NASA::if x { ... }`,
if x { ... }      // causing several confusing syntax errors.
```

Forbidding it, however, has a cost: it restricts the code styles developers can
use. If a developer wants to put a line break in the middle of a name with a
module selector, they will not be able to format it like this:

```swift
SuperLongAndComplicatedModuleName::
  superLongAndComplicatedFunctionName()
```

And will have to write it like this instead: 

```swift
SuperLongAndComplicatedModuleName
  ::superLongAndComplicatedFunctionName()
```

The member-lookup `.` operator has a similar restriction, but developers may
not want to style them in exactly the same way, particularly since C++
developers often split a line after a `::`.

  [SE-0071]: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0071-member-keywords.md> "Allow (most) keywords in member references"
  [SE-0364]: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0364-retroactive-conformance-warning.md> "Warning for Retroactive Conformances of External Types"
  [SE-0382-review-2]: <https://forums.swift.org/t/se-0382-second-review-expression-macros/63064> "SE-0382 (second review): Expression Macros"
  [SE-0444]: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md> "SE-0444 Member Import Visibility"
