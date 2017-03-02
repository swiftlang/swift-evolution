# A Consistent Foundation For Access Control: Scope-Bounded Capabilities

* Proposal: [SE-NNNN](NNNN-scope-bounded-capabilities.md)
* Authors: [Matthew Johnson](https://github.com/anandabits)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal introduces a consistent foundation for all access control in Swift: scope-bounded capabilities.  The existing access control features are generalized with a single mechanism that unifies their semantics.  This unified mechanism eliminates the inessential complexity and inconsistency of the current system while expanding its utility. 

[Swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170227/033389.html)

## Motivation

The new access control features in Swift 3 have proven to be extremely controversial.  The most common refrain is that we need a more simple system.  In order to accomplish this we need to do more than tweak the system we already have.  We need to revisit the foundation of the system itself.

### Simple Made Easy

Rich Hickey gave a fantastic talk called [Simple Made Easy](https://www.infoq.com/presentations/Simple-Made-Easy).  In this talk Rich explores the etymology and relationship of the words "simple", "complex", and "easy".  The meanings he explores are:

* Complex: entangled, intertwined, interleaved, braided together
* Simple: one strand, single focus, disentangled
* Easy: familiar, nearby, readily at hand

The central point Rich makes in this talk is that when a design entangles two orthogonal concepts complexity is the result.  He coins the term "complect" to refer to this kind of inessential complexity.  This complexity can be removed by disentangling the concepts.  Instead of "complecting" independent concerns we can *compose* them.  

The result is a simpler system.  It is simpler because independent concepts can be considered and understood independently of each other.

The composition of independent concerns also results in a more flexible system.  When orthogonal concepts are entangled it is more difficult to extend the system to meet future needs.  One concept cannot be extended independently of the other.  It is not possible to make independent decisions about what should be orthogonal aspects of the design.

Rich believes that the programming community is often too quick to reach for an immediately "easy" solution.  Unfortunately, the "easy" solution often entangles concepts and are therefor actually complex.  He suggests that we *first* design a simple (i.e. disentangled) solution and then layer ease of use and familiarity on top, thus the title "Simple Made Easy".


### Two orthogonal concepts

The access control system in Swift 3 incorporates two orthogonal concepts: availability and capability.  Availability is what immediately comes to mind when one thinks of access control: a symbol is either available or it is not.  Capability is more nuanced.  It refers to what you can *do* with that symbol.

Each declaration supports a *basic* capability which is always available when the symbol itself is available.  Many declarations also offer *additional* capabilities (such as the ability to inherit, override, set a property, etc).  These additional capabilities may be *less available* than the symbol itself.

In Swift, availability is always specified in terms of a scope.  Swift does not currently have a consistent way to talk about capabilities.  Thus far we have introduced new syntax every time we wish to distinguish the availability of an *additional* capability from that of the symbol itself:

* `open` vs `public` access modifiers classes and methods
* Access modifier parameterization for setter availability: `private(set)`
* The `@closed` attribute which has been discussed as a way to specify non-resilient enums in Swift 4*

It is clear that we need to be able to talk about not just basic availability, but also *capabilities*.  It would be very nice if we had **one** consistent way to do this.  This can be accomplished by composing the concepts of availability and capability into the notion of a *scope-bounded capability*.  

*`@closed` would lie outside the access control system proper.  It is included for the sake of completeness.  It is also included to demonstrate how the language currently lacks a clear and obvious way to specify new capability bounds when they are arise.


### Problems with Swift's access control system

Swift's current access control system has several problems.

#### Inconsistency

As noted above, the ways *additional* capabilities are bounded is inconsistent.  The semantics of `public` are also inconsistent.  

##### Internal default

The Swift evolution community has adopted the principle that nothing should be available outside a module without an explicit declaration of intent by a library author.  This is an excellent default which protects library authors against making an error of omission that would require a breaking change to correct.  Unfortunately this principle has not been consistently applied.

##### `public`

In *most* cases `public` only provides access to the *basic* capability a declaration offers.  This is true by definition for declarations that do not offer *additional* capabilities but it is *also* true for classes (with respect to inheritance) and class methods (with respect to overrides).  

However, there are three cases where `public` currently provides access to *additional* capabilities:

* `public var` allows access to the setter
* `public enum` allows exhaustive switch
* `public protocol` allows new conformances to be introduced

It is not currently possible to declare resilient enums or closed protocols but both have received significant discussion.  Further, resilient enums need to be supported before ABI stability is declared.  A consistent access control system would treat these as independent capabilities that are not made available with a simple `public` declaration.


#### `private` and `fileprivate`

The most heavily debated aspect of the changes to the access control system in Swift 3 is without question the change in meaning of `private` to be the current lexical scope and the renaming of the file-level scope to `fileprivate`.  This change was made with the idea that a lexically scoped `private` would prove to be a good "soft default" for a less-than-module availability bound.  While many users appreciate the semantics of a scope-based access modifier it has not proven to be a good "soft default" and therefore does not deserve the name `private`.

##### Extensions

In languages without extensions lexically scoped availability is equivalent to type-based availability for members of a type.  In such a language it could make a reasonable default.  Swift is not such a language.  

Using several extensions on the same type within the same file is an extremely common Swift idiom.  This idiom is not well supported by a "soft default" of scope-based availability.  The tension between a pervasive idiom and the "soft default" leads to confusion about when scope-based a availability is appropriate, and often an overuse of the feature.  It also leads to the need to use `fileprivate` much more frequently than is desirable for such an awkward keyword.

##### Types and members

A "soft default" should not have subtle behavior that has the potential to confuse beginners.  Most beginners would expect `Foo` and `bar` in the following example to have the same visibility.  This was true in Swift 2 but it is not true in Swift 3.

```swift
private struct Foo {
	private var bar = 42
}
```

##### An advanced feature

Lexically scoped availability has important uses such as preserving invariants.  All access to invariant-related state can be routed through basis methods which access the state carefully without violating invariants, even when that access happens in an extension in the same file.  We should not abandon this tool but it should not be the "soft default".  It is best reserved for specific use cases where the guarantee it offers is important to correctess of the software.


### Essential and inessential complexity

The inconsistencies noted above and a bad "soft default" of `private` are all forms of *inessential* complexity.  This makes Swift's access control system more difficult to understand and use than it needs to be and causes confusion.

At the same time the *essential* complexity of capabilities that are bounded independent of basic symbol availability is not explicitly acknowledged and embraced.  This also makes the access control system more difficult to understand and use than it should be.  Users are not taught to think in terms of independently bounded capabilities.  This is a concept that *could* be learned once and applied generally if it was more visible in the language.


## Proposed solution

The proposed solution is to establish a semantic foundation for access control that is *simple* in the sense of composing rather than interleaving independent concerns.  The solution is made *easy* by defining familiar names in terms of this foundation while preserving the semantics Swift users expect them to have.  It is *consistent* in its use of a single mechanism for bounding capabilities and its default of `internal` for *all* capabilities.

For readers who skipped the motivation section, this proposal uses the term "capability" to refer to things you can *do* with a declaration.  For example, you can *call* functions and you can also *override* class methods.  You can *get* the value of any property and some properties also allow you to *set* their value.

### Scope-bounded capabilities

All access control is defined in terms of a parameterized access modifier that allows the user to specify a capability and a scope that bounds that capability.

```swift
// Access to the setter is bounded to the current file.
access(set, file) var foo = 42
```

The default argument for the capability is simply the *basic* capability the declaration provides.  For a variable this is the getter, for a method it is the ability to call the method, for a type it is the ability to use the type and so on.

```swift
// Access to the getter is bounded to the current file.
access(file) var bar = 42
```

The scope of the basic capability implicitly bounds additional capabilities: if basic use of a symbol is not available it is not possible to do anything with that symbol.  This is similar to the existing rule that a type implicitly bounds the availability of all symbols declared within its scope: a `public` property of an `internal` type is not available outside the module because the type itself is not available.

### Aliases

This modifier is simple (in the sense defined above), general and powerful.  However it is also unfamiliar, often slightly verbose, and offers a very wide configuration space.  Familiar aliases are provided as "soft defaults" which are recommended for common use cases.

These aliases introduce no additional semantics.  Once a user understand scopes, capabilities and how they compose to produce scope-bounded capabilities the user also has the ability to understand *all* aliases we introduce.  Tools could even make the definition of the alias available to remind the user of its underlying meaning (similarly to they way Xcode allows a user to command-click to see a symbol definition).

These aliases are defined in terms of the parameterized `access` modifier:

* scoped(capability) = access(capability, lexical)
* private(capability) = access(capability, file)
* internal(capability) = access(capability, submodule)
* public(capability) = access(capability, everywhere)
* open = access(inherit, everywhere) 
* open = access(override, everywhere)
* final = access(inherit, nowhere)
* final = access(override, nowhere)
* closed = access(exhaustiveSwitch, everywhere)

`scoped` is introduced with semantics equivalent to that of `private` in Swift 3.

`private` reverts to the Swift 2 semantics.

`internal` is specified in terms of `submodule` and is equivalent to `module` scope until submodules are introduced.  It is specified this way to indicate the intent of the author should submodules be added.  This proposal does not introduce an alias for module-wide scope in the presence of submodules.  Such an alias could be introduced as part of or after a submodule proposal is accepted.

`open` and `final` are overloaded based on the kind of declaration they are applied to, specifying the `inherit` capability for classes and the `override` capability for class methods.

`closed enum` provides semantics equivalent to `public enum` in Swift 3.  `public enum` receives the semantics of resilient enums in this proposal.  


### Scopes

The hierarchy of scopes is as follows:

* nowhere
* lexical
* LexicalScopeName*
* file
* submodule
* SubmoduleName
* module
* everywhere

The name of any **ancestor** lexical scope or submodule of a declaration, including the immediately containing type or submodule, form the set of valid user-defined scope references.

Including `nowhere` allows us to define `final` in terms of this system.  It also allows us to model all properties and functions with the same set of capabilities: the setter of a read only property is automatically bounded to `nowhere` and the `override` capability of a function that is not a class method is automatically bounded to `nowhere`.

Allowing users to reference any ancestor scope introduces affords advanced users a degree of control that is not possible in the current access control system.  If submodules are introduced into Swift this additional control will be especially useful as a means to facilitate bounded collaboration between peer submodules allowing them to communicate in ways not available to the rest of the module.

*The only lexical scopes that have names and also contain declarations with access modifiers are currently type declarations.  In the future other kinds of lexical scopes may have also names.  For example there has been some discussion of allowing extensions to have names (for example to support definitive initialization of stored properties in extensions).

*Note:* This proposal intentionaly avoids type-based scope specifiers such as the alternative semantic for `extension` discussed above, `protected` and the use of type names in the manner of C++ `friend`.  The purpose of access control is compiler verified encapsulation.  Since anybody can add an extension or subclass anywhere the compiler can't really offer any useful verification of encapsulation for any type-based scheme.

*Note:* Early drafts of this proposal included a scope called `extension` which would be available for declarations which occur inside the scope of an extension.  This was included to support references to to the scope of the extension by types declared inside the extension.  It was removed because this is a narrow edge case and will not be necessary if extensions can have names in the future.

#### Why not use `public`, `private` and `internal` as scope names?

* It clarifies the distinction between scopes and aliases.
* The scope names `module` and `submodule` follow the same pattern as `file`.
* There is a nice symmetry between `nowhere` and `everywhere`.

### Capabilities

The capabilities available depend on the kind of declaration an access modifier is applied to.  All declarations offer a *basic* capability that is always available when the declaration itself is available.  The basic capability is specified by default when the scope modifier or a parameterized alias is used without an explicit capability argument.  Some declarations also offer *additional* capabilities which may have an independent bound applied to them.  All capabilities, including *additional* capabilities have a default bound of `internal` or (sub)module.

#### Properties and subscripts

* `get` (the basic capability)
* `set` (for readwrite properties only)
* `override` (for class properties only)

#### Functions and initializers

* `call` (the basic capability)
* `override` (for class methods only)

#### Types

* `use` (the basic capability)
* `inherit` (for classes)
* `exhaustiveSwitch` (for enums)

#### Protocols

* `use` (the basic capability)
* `conform`

#### Extensions and typealiases

* `use` (the basic capability)

*Note:* The name `use` is very abstract.  The idea is that you can *use* the type: work with values, access static members, use a protocol as a constraint or existential, etc.  It is difficult to come up with a good name that conveys this meaning.  Bikeshedding is welcome.  The good news is that because this is the basic capability it does not need to be mentioned explicitly in code.

### Relationship of capabilities to one another

In the current model the only relationship between capabilities is between the *basic* capability and each *additional* capability.  The semantics of this relationship is that the scope of the *basic* capability implicitly bounds the availability of all *additional* capabilities.  Additionally, when the bound of the *basic* capability is not explicitly specified and one or more *additional* capabilities have a bound that is *greater* than the default of `internal` (aka (sub)module) the bound of the *basic* capability is implicitly lifted as necessary to make both the *basic* and *additional* capability available in the specified scope.

It is conceivable that additional semantic relationships between capabilities may be necessary in the future.  For example, it is conceivable that we could allow the `exhaustiveSwitch` capability to be available outside the declaraing module for classes and protocols.  This would necessarily be mutually exclusive with exposing the `inherit` capability outside the module.  Supporting sophisticated semantic relationships like this is not necessary to introduce the model of scope-bounded capabilities for the current feature set of Swift.  The model may be enhanced to support more sophisticated semantic relationships between capabilities if that becomes necessary in the future.

### Scalable in the future

As the language grows the mechanism of scope-bounded capabilities can be extended in an obvious way to meet the needs of future declarations and capabilities.  Users are only required to learn about the new declaration or capability that was introduced.  Their existing knowledge of the scope-bounded capability access control system is immediately applicable.


## Detailed design

### Rules

The rules which make up the *essential* complexity in Swift's access control system are:

* The default scope for all capabilites a declaration offers is module-wide (or submodule-wide in the future).
* The scope of a capability may be modified by an explicit access modifier.
* The scope of an *additional* capability is implicitly bounded by the scope of the *basic* capability.
* The scope of an *additional* capability may not be explicitly specified as greater than that of the *basic* capability.
* If no scope is explicitly provided for the *basic* capability and an *additional* capability is specified to be available outside the (sub)module the *basic* capability is also given the same availability.
* The scope of a declaration (including all capabilities) may be bounded by the declaration of ancestor.
* The scope of a declaration may not be greater than the scope of the capabilities necessary to use that declaration: if you can't see a parameter type you can't call the function.

Most of these rules already exist in Swift's access control system.  There is one change and one addition:

* The first rule changes the availability of the *additional* capability of `public` readwrite properties, protocols and enums.
* The fifth rule affords shorthand for implicitly making the *basic* capability `public` when an *additional* capability is also made public.

### Grammar

The changes to the access modifier grammar are as follows:

```
access-level-modifier → access­(­ scope-specifier ­)­ | access­( capability-specifier ­, scope-specifier ­)­
access-level-modifier → scoped­ | scoped­(­ capability-specifier ­)­
access-level-modifier → private­ | private­(­ capability-specifier ­)­
access-level-modifier → internal­ | internal­(­ capability-specifier ­)­
access-level-modifier → public­ | public­(­ capability-specifier ­)­
access-level-modifier → open­
access-level-modifier → final
access-level-modifier → closed

scope-specifier → nowhere | extension | file | submodule | module | everywhere | identifier
capability-specifier → set | inherit | override | conform | exhaustiveSwitch
```

### Playground

A Swift playground that includes a prototype of the basic scope-bounded capability access modifier as well as the aliases is available [here](NNNN-scope-bounded-capabilities.playground.zip).


## Future possibilities

### Bound refinements

Many people have asked for various kinds of type-based access modifiers to be added to Swift.  Features like this could be introduced by adding a third parameter which allows users to *refine* the bound of a capability.  This third parameter default to allowing access everywhere within the scope that bounds the capability.  When it is explicitly specified the parameter would restrict access to extensions, subclasses or conformances of a type or ancestor of the declarations.  

For example, assuming `bar` is a member of `Foo` or a descendent of `Foo`:

```swift
// Restricts access to the setter to Foo and its extensions and subclasses,
// but only those which are declared inside the same submodule as this declaration:
access(set, submodule, Foo(extensions, subclasses)) var bar: Int
```

This feature would allow us to introduce an alias `protected` if we wanted to do that:

`protected(capability, scope) = access(capability, scope, Self(subclasses))`

### Additional uses of the `nowhere` scope

Scope-bounded capabilities are able to express `set`-only properties and `override`-only methods with a minor change to the rules of the system.  This model could also be used to express the idea of `abstract` types if an `init` capability was factored out*.  

These features have been requested on the list in the past.  In the case of `override`-only methods there are known examples in Apple's frameworks.  Allowing support for these would add some complexity to the model and is not essential to establishing a consistent basis for the existing access control feature.

\*This model cannot be used to express `abstract` members because the semantics of `abstract` members is that they *require* an overload.  Access control is not able to specify *requirements*.


## Source compatibility

With two exceptions, this proposal will not cause any Swift 3 source to fail to compile but will produce different behavior in four cases.  In all cases a mechanical migration is possible.

### `fileprivate`

This proposal deprecates `fileprivate`.  This keyword should be supported for at least one release with a deprecation warning and eventually removed.

### `private`

This proposal reverts the meaning of `private` to file scope.  This will usually not break any code but many users will want to convert existing uses of `private` to `scoped` during migration to Swift 4.  When a user has declared mutually ambiguous or duplicate `private` symbols in different scopes in the same file migration to `scoped` is required.  An example of this is:

```swift
struct Foo {
    private bar() { ... }
}
extension Foo {
    private bar() { ... }
}
```

### `public var`

This proposal removes the availability of the setter of a `public var` outside the module, requiring `public(set) var` to expose the setter.  This requires a migration of existing code.  We could ease this transition with a deprecation warning in one release and then introduce the semantic change in the following release.

### `public enum`

This proposal removes the availability of exhaustive switch from public enums.  Non-resilient enums will need to be declared as a `closed enum`.  As with `public var`, a deprecation warning and deferred semantic change could be used to ease the transition.

### `public protocol`

This proposal requires protocols conformable outside the module to use the `open protocol` alias rather than `public protocol`.  Visible but not conformable protocols are out of scope for Swift 4.  This means that in Swift 4 `open protocol` and `public protocol` could share the same semantics with a deprecation warning on `public protocol` telling users to use `open` and that the semantics of `public protocol` will be different in the future.  We could remove support for `public protocol` in a point release, reserving it until we introduce the ability for a protocol to be visible but not conformable.


## Effect on ABI stability

If this proposal impacts ABI stability it would be in the area of runtime metadata or introspection.  Input on this topic is welcome.

## Effect on API resilience

This proposal does not impact API reslience.  The proposed solution recasts some existing features but does so in a way that should be backwards compatible.  No existing semantics are changed, only how those semantics are stated syntactically.

## Alternatives considered

The primary alternative is to continue using the ad-hoc approach to meeting our access control needs.  There have been many different ideas about how we might be able to simplify the current system by removing or slightly tweaking some of the existing features.  The author believes this approach will not be able to meet future needs well and will continue to be burdened by the accumulation of inessential complexity.  This situation will get worse, not better, as new features are added to the language.

### `scope` instead of `access`

The initial draft of this proposal used the name `scope` for the fundamental access modifier.  This modifier read as follows: "the scope of the getter is the file".  It was also specified to have a default scope argument of `lexical`, allowing it to be used without any arguments in the same way the `scoped` alias is in the current draft.  This avoids introducing an extra keyword but was deemed more confusing than it should be.  It also makes more sense that the fundamental access modifier is simply named `access` and places scopes and capabilities on equal syntactic footing.

## Acknowledgements

Jaden Geller provided very valuable feedback on the early drafts of this proposal, including suggestion to change the name of the fundamental access modifier to `access`.