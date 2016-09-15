# Flexible Memberwise Initialization

* Proposal: [SE-0018](0018-flexible-memberwise-initialization.md)
* Author: [Matthew Johnson](https://github.com/anandabits)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Deferred**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006469.html)

## Introduction

The Swift compiler is currently able to generate a memberwise initializer for use in some circumstances, however there are currently many limitations to this.  This proposal builds on the idea of a compiler generated memberwise initializer, making the capability available to any initializer that opts in.

Swift-evolution thread: [Proposal Draft: flexible memberwise initialization](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/003902.html)

## Motivation

When designing initializers for a type we are currently faced with the unfortunate fact that the more flexibility we wish to offer users the more boilerplate we are required to write and maintain.  We usually end up with more boilerplate and less flexibility than desired.  There have been various strategies employed to mitigate this problem, including:

1. Sometimes properties that should be immutable are made mutable and a potentially unsafe ad-hoc two-phase initialization pattern is employed where an instance is initialized and then configured immediately afterwards.  This allows the developer to avoid including boilerplate in every initializer that would otherwise be required to initialize immutable properties.

2. Sometimes mutable properties that have a sensible default value are simply default-initialized and the same post-initialization configuration strategy is employed when the default value is not correct for the intended use.  This results in an instance which may pass through several states that are incorrect *for the intended use* before it is correctly initialized for its intended use.

Underlying this problem is the fact that initialization scales with M x N complexity (M members, N initializers).  We need as much help from the compiler as we can get!

Flexible and concise initialization for both type authors and consumers will encourages using immutability where possible and removes the need for boilerplate from the concerns one must consider when designing the intializers for a type.

Quoting [Chris Lattner](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151130/000518.html):

	The default memberwise initializer behavior of Swift has at least these deficiencies (IMO):
	1) Defining a custom init in a struct disables the memberwise initializer, and there is no easy way to get it back.
	2) Access control + the memberwise init often requires you to implement it yourself.
	3) We don’t get memberwise inits for classes.
	4) var properties with default initializers should have their parameter to the synthesized initializer defaulted.
	5) lazy properties with memberwise initializers have problems (the memberwise init eagerly touches it).

Add to the list “all or nothing”.  The compiler generates the entire initializer and does not help to eliminate boilerplate for any other initializers where it may be desirable to use memberwise intialization for a subset of members and initialize others manually.

It is common to have a type with a number of public members that are intended to be configured by clients, but also with some private state comprising implementation details of the type.  This is especially prevalent in UI code which may expose many properties for configuring visual appearance, etc.  Flexibile memberwise initialization can provide great benefit in these use cases, but it immediately becomes useless if it is "all or nothing".  

We need a flexible solution that can synthesize memberwise initialization for some members while allowing the type author full control over initialization of implementation details.

## Proposed solution

I propose adding a `memberwise` declaration modifier for initializers which allows them to *opt-in* to synthesis of memberwise initialization.  

This proposal adopts a model for property eligibility where stored properties automatically receive memberwise initialization parameters unless they are deemed ineligible for one of several reasons.  An *opt-in* model using a `memberwise` declaration modifier allowing properties to *opt-in* to memberwise initialization synthesis is also possible.  

The two approaches are not mutually exclusive: it is possible to use the *automatic* model when no properties have the `memberwise` declaration modifier and the *opt-in* model when one or more properties do have the `memberwise` declaration modifier.  A future enhancement to this proposal may introduce the *opt-in* model, allowing programmers to choose which model is preferred for a specific type they are authoring.

The *automatic* model of the current proposal determines the set of properties that receive memberwise initialization parameters by considering *only* the initializer declaration and the declarations for all properties that are *at least* as visible as the initializer (including any behaviors attached to the properties).  The rules are as follows:

1. The access level of the property is *at least* as visible as the memberwise initializer.  The visiblity of the **setter** is used for `var` properties.
2. They do not have a behavior which prohibits memberwise initialization (e.g. the 'lazy' behavior).
3. If the property is a `let` property it *may not* have an initial value.

The parameters are synthesized in the parameter list in the location of the `...` placeholder.  It is a compile-time error for a memberwise initializer to omit the `...` placeholder.  The parameter list is ordered as follows:

1. All parameters **without** default values precede parameters **with** default values.
2. Within each group, parameters follow property declaration order.

Under the current proposal only `var` properties could specify a default value, which would be the initial value for that property.   It may be possible for `let` properties to specify a default value in the future using the `@default` enhancement or some other mechanism allowing the default value to be specified.

## Examples

This section of the document contains several examples of the solution in action.  It *does not* cover every possible scenario.  If there are concrete examples you are wondering about please post them to the list.  I will be happy to discuss them and will add any examples we consider important to this section as the discussion progresses.

Specific details on how synthesis is performed are contained in the detailed design.

### Replacing the current memberwise initializer

```swift
struct S {
	let s: String
	let i: Int

	// user declares:
	memberwise init(...) {}
	// compiler synthesizes:
	init(s: String, i: Int) {
		/* synthesized */ self.s = s
		/* synthesized */ self.i = i
	}
}
```

### Var properties with initial values

NOTE: this example is only possible for `var` properties due to the initialization rules for `let` properties.  If the initializer expression contains side effects, then the side effect is not evaluated if passed in explicitly by a caller of the memberwise initializer.

```swift
struct S {
	var s: String = "hello"
	var i: Int = 42

	// user declares:
	memberwise init(...) {}
	// compiler synthesizes:
	init(s: String = "hello", i: Int = 42) {
		/* synthesized */ self.s = s
		/* synthesized */ self.i = i
	}
}
```

### Access control

```swift
struct S {
	let s: String
	private let i: Int

	// user declares:
	memberwise init(...) {
		// compiler error, i memberwise initialization cannot be synthesized 
		// for i because it is less visible than the initializer itself
	}
}
```

```swift
struct S {
	let s: String
	private let i: Int

	// user declares:
	memberwise init(...) {
		i = 42
	}
	// compiler synthesizes (suppressing memberwise initialization for properties with lower visibility):
	init(s: String) {
		/* synthesized */ self.s = s
		
		// body of the user's initializer remains
		i = 42
	}
}
```

### Manually declared parameters

```swift
struct S {
	let s: String
	private let i: Int

	// user declares:
	memberwise init(anInt: Int, anotherInt: Int, ...) {
		i = anInt > anotherInt ? anInt : anotherInt
	}
	// compiler synthesizes (suppressing memberwise initialization for properties with lower visibility):
	init(anInt: Int, anotherInt: Int, s: String) {
		/* synthesized */ self.s = s
		
		// body of the user's initializer remains
		i = anInt > anotherInt ? anInt : anotherInt
	}
}
```

### Lazy properties and incompatible behaviors

```swift
struct S {
	let s: String
	lazy var i: Int = InitialValueForI()

	// user declares:
	memberwise init(...) {
	}
	// compiler synthesizes:
	init(s: String) {
		/* synthesized */ self.s = s
		
		// compiler does not synthesize initialization for i 
		// because it contains a behavior that is incompatible with 
		// memberwise initialization.
	}
}
```

## Detailed design

### Syntax changes

This proposal introduces two new syntactic elements: the `memberwise` declaration modifier and the `...` memberwise parameter placeholder.

Designated initializers opt-in to synthesized memberwise initialization with the `memberwise` declaration modifier.  This modifier will cause the compiler to follow the procedure outlined later in the design to synthesize memberwise parameters as well as memberwise initialization code at the beginning of the initializer body.  

### Overview

Throughout this design the term **memberwise initialization parameter** is used to refer to initializer parameters synthesized by the compiler as part of **memberwise initialization synthesis**.

#### Algorithm

1. Determine the set of properties eligible for memberwise initialization synthesis.  Properties are eligible for memberwise initialization synthesis if:

	1. The access level of the property is *at least* as visible as the memberwise initializer.  The visiblity of the **setter** is used for `var` properties.
	2. They do not have a behavior which prohibits memberwise initialization.
	3. If the property is a `let` property it *may not* have an initial value.

2. Determine the default value, if one exists, for each *memberwise initialization parameter*.  Under the current proposal only `var` properties could specify a default value, which would be the initial value for that property.   
	
3. If the initializer declares any parameters with external labels matching the name of any of the properties eligible for memberwise initialization report a compiler error.

4. Synthesize *memberwise initialization parameters* in the location where the `...` placeholder was specified.  The synthesized parameters should have external labels matching the property name.  Place the synthesized parameters in the following order:
	1. All parameters **without** default values precede parameters **with** default values.
	2. Within each group, follow property declaration order.
	
5. Synthesize initialization of all *memberwise initialization parameters* at the beginning of the initializer body.

6. If the initializer body assigns to a `var` property that received memberwise initialization synthesis report a warning.  It is unlikely that overwriting the value provided by the caller is the desired behavior.

## Impact on existing code

This proposal will also support generating an *implicit* memberwise initializer for classes and structs when the following conditions are true:

1. The type declares no initializers explicitly.
2. The type is:
	1. a struct
	2. a root class
	3. a class whose superclass has a designated intializer requiring no arguments

The implicitly generated memberwise initializer will have the highest access level possible while still allowing all stored properties to be eligible for memberwise parameter synthesis, but will have at most `internal` visibility.  Currently this means its visibility will be `internal` when all stored properties of the type have setters with *at least* `internal` visibility, and `private` otherwise (when one or more stored properties are `private` or `private(set)`).

The *implicitly* synthesized initializer will be identical to an initializer declared *explicitly* as follows: `memberwise init(...) {}` or `private memberwise init(...) {}`.

NOTE: Because the `memberwise` declaration modifier only applies to designated initializers, it may not be used with class initializers defined in an extension.  It may be used with struct initializers defined in an extension as long as all of the struct's stored properties are visible to the extension.

The changes described in this proposal are *almost* entirely additive.  The only existing code that will break will be in the case of structs with stored `private` properties or `var` properties that have `private` setters which had been receiving an `internal` implicitly synthesized memberwise initializer.  Options for addressing this impact are:

1. If the implicitly synthesized memberwise initializer was only used *within* the same source file no change is necessary.  An implicit `private` memberwise initializer will still be synthesized by the compiler.
2. A mechanical migration could generate the explicit code necessary to declare the previously implicit initializer.  This would be an `internal` memberwise initializer with *explicit* parameters used to manually initialize the stored properties with `private` setters.
3. If the "Access control for init" enhancement were accepted the `private` members could have their access control modified to `private internal(init)` which would allow the implict memberwise intializer to continue to have `internal` visibility as all stored properties would be eligible for parameter synthesis by an `internal` memberwise initializer.

The only other impact on existing code is that memberwise parameters corresponding to `var` properties with initial values will now have default values.  This will be a change in the behavior of the implicit memberwise initializer but will not break any code.  The change will simply allow new code to use that initializer without providing an argument for such parameters.

## Future enhancements

In the spirit of incremental change, the current proposal is focused on core functionality.  It is possible to enhance that core functionality with additional features.  These enhancements may be turned into proposals after the current proposal is accepted.

### @default

It is not possible under the current proposal to specify a default value for memberwise initialization parameters of `let` properties.  This is an unfortunate limitation and a solution to this is a highly desired enhancement to the current proposal.

One possible solution would be to introduce the `@default` attribute allowing `let` properties to specify a default value for the parameter the compiler synthesizes in memberwise initializers.

There are two possible syntactic approaches that could be taken by `@default`:

1. Make `@default` a modifier.  The same syntax is used as for initial values, but when the `@default` attribute is specified for a property the specified value is a default rather than an initial value.
2. Allow the default value to be specified using an attribute argument.

Each syntax has advantages and disadvantages:

1. The first syntax is arguably cleaner and more readable.
2. The first syntax makes it impossible to specify both an initial value **and** a default value for the same property.  This is advantageous because a `let` property should never have both and initial values for `var` properties are effectively just a default value anyway.
3. The second syntax may have less potential for confusion and thus more clear as it uses significantly different syntax for specifying initial and default values.

#### Example using the first syntax option

```swift
struct S {
	@default let s: String = "hello"
	@default let i: Int = 42

	// user declares:
	memberwise init(...) {}
	// compiler synthesizes:
	init(s: String = "hello", i: Int = 42) {
		/* synthesized */ self.s = s
		/* synthesized */ self.i = i
	}
}
```

#### Example using the second syntax option

```swift
struct S {
	@default("hello") let s: String
	@default(42) let i: Int

	// user declares:
	memberwise init(...) {}
	// compiler synthesizes:
	init(s: String = "hello", i: Int = 42) {
		/* synthesized */ self.s = s
		/* synthesized */ self.i = i
	}
}
```

### `memberwise` properties

The rules of the current proposal are designed to synthesize memberwise parameters for the correct set of properties as best as possible.  Of course there will be times when the rules don't match what is desired.

Introducing a `memberwise` declaration modifier for properties would allow programmers to specify exactly which properties should participate in memberwise initialization synthesis.  It allows full control and has the clarity afforded by being explicit.

Specifc use cases this feature would support include allowing `private` properties to receive synthesized memberwise parameters in a `public` initializer, or allow `public` properties to be omitted from parameter synthesis.

An example of this

```swift
struct S {
  // both properties receive memberwise initialization parameters
  // regardless of access control.
  memberwise public let s: String
  memberwise private let i: Int

  // neither property receives a memberwise initialization parameter
  // regardless of access control.
  public var s2 = ""
  private var i2 = 42

  // user declares:
  memberwise init(...) {}

  // compiler synthesizes:
  init(s: String, i: Int) {
    /* synthesized */ self.s = s
    /* synthesized */ self.i = i
  }
}
```


### Access control for init

In some cases it may be desirable to be able to specify distinct access control for memberwise initialization when using the *automatic* model, for example if that model *almost* has the desired behavior, but the initialization visibiltiy of one property must be adjusted to produce the necessary result.

The syntax used would be identical to that used for specifying distinct access control for a setter.  This feature would likely have its greatest utility in allowing more-private members to participate in more-public memberwise initializers.  It may also be used to inhibit memberwise initialization for some members, although that use would usually be discouraged if the `@nomemberwise` proposal were also accepted.

```swift
struct S {
	private internal(init) let s: String
	private i: Int

	// user declares:
	memberwise init(...) {
		i = getTheValueForI()
	}
	// compiler synthesizes (including a parameter for private member s despite the fact that this is an internal memberwis initializer):
	init(s: String) {
		/* synthesized */ self.s = s
		
		// body of the user's initializer remains
		i = getTheValueForI()
	}
}
```

If this enhancement were submitted the first property eligibility rule would be updates as follows:

1. Their **init** access level is *at least* as visible as the memberwise initializer.  If the property does not have an **init** acccess level, the access level of its **setter** must be *at least* as visible as the memberwise initializer.

### @nomemberwise

There may be cases where the author of a type would like to prevent a specific property from participating in memberwise initialization either for all initializers or for a specific initializer.  The `@nomemberwise` attribute for properties and initializers supports this use case.

Memberwise initializers can explicitly prevent memberwise initialization for specific properties by including them in a list of property names provided to the `@nomemberwise` attribute like this: `@nomemberwise(prop1, prop2)`.

Under the *automatic* model, properties would be able to explicitly opt-out of memberwise initialization with the `@nomemberwise` attribute.  When they do so they would not be eligible for memberwise initialization synthesis.  Because of this they must be initialized directly with an initial value or initialized directly by every initializer for the type.

The `@nomemberwise` attribute would introduce two additional eligibility rules when deterimining which properties can participtate in memberwise initialization.

1. The property **is not** annotated with the `@nomemberwise` attribute.
2. The property **is not** included in the `@nomemberwise` attribute list attached of the initializer.  If `super` is included in the `@nomemberwise` attribute list **no** superclass properties will participate in memberwise initialization.

#### Examples

NOTE: This example doesn't really save a lot.  Imagine ten properties with only one excluded from memberwise initialization.

```swift
struct S {
	let s: String
	let i: Int

	// user declares:
	@nomemberwise(i)
	memberwise init(...) {
		i = getTheValueForI()
	}
	// compiler synthesizes (suppressing memberwise initialization for properties mentioned in the @nomemberwise attribute):
	init(s: String) {
		/* synthesized */ self.s = s
		
		// body of the user's initializer remains
		i = getTheValueForI()
	}
}
```

```swift
struct S {
	let s: String
	@nomemberwise let i: Int

	// user declares:
	memberwise init() {
		i = 42
	}
	// compiler synthesizes:
	init(s: String) {
		/* synthesized */ self.s = s
		
		// body of the user's intializer remains
		i = 42
	}
}
```

### Memberwise initializer chaining / parameter forwarding

Ideally it would be possible to define convenience and delegating initializers without requiring them to manually declare parameters and pass arguments to the designated initializer for memberwise intialized properties.  It would also be ideal if designated initializers also did not have to the same for memberwise intialization parmaeters of super.

A general solution for parameter forwarding would solve this problem.  A future parameter forwarding proposal to support this use case and others is likely to be pursued.

### Objective-C Class Import

Objective-C frameworks are extremely important to (most) Swift developers.  In order to provide the call-site advantages of flexible memberwise initialization to Swift code using Cocoa frameworks a future proposal could recommend introducing a `MEMBERWISE` attribute that can be applied to Objective-C properties and initializers.

Mutable Objective-C properties could be marked with the `MEMBERWISE` attribute.  Readonly Objective-C properties **could not** be marked with the `MEMBERWISE` attribute.  The `MEMBERWISE` attribute should only be used for properties that are initialized with a default value (not a value provided directly by the caller or computed in some way) in **all** of the class's initializers.

Objective-C initializers could also be marked with the `MEMBERWISE` attribute.  When Swift imports an Objective-C initializer marked with this attribute it could allow callers to provide memberwise values for the properties declared in the class that are marked with the `MEMBERWISE` attribute.  At call sites for these initializers the compiler could perform a transformation that results in the memberwise properties being set with the provided value immediately after initialization of the instance completes.

It may also be desirable to allow specific initializers to hide the memberwise parameter for specific properties if necessary.  `NOMEMBERWISE(prop1, prop2)`

It is important to observe that the mechanism for performing memberwise initialization of Objective-C classes (post-initialization setter calls) must be implemented in a different way than native Swift memberwise initialization.  As long as developers are careful in how they annotate Objective-C types this implementation difference should not result in any observable differences to callers.  

The difference in implementation is necessary if we wish to use call-site memberwise initialization syntax in Swift when initializing instances of Cocoa classes.  There have been several threads with ideas for better syntax for initializing members of Cocoa class instances.  I believe memberwise initialization is the *best* way to do this as it allows full configuration of the instance in the initializer call. 

Obviously supporting memberwise initialization with Cocoa classes would require Apple to add the `MEMBERWISE` attribute where appropriate.  A proposal for the Objective-C class import provision is of significantly less value if this did not happen.  My recommendation is that an Objective-C import proposal should be drafted and submitted if this proposal is submitted, but not until the core team is confident that Apple will add the necessary annotations to their frameworks.

## Alternatives considered

### Require stored properties to opt-in to memberwise initialization

This is a reasonable option and and I expect a healthy debate about which default is better.  The decision to adopt the *automatic* model by default was made for several reasons:

1. The memberwise initializer for structs does not currently require an annotation for properties to opt-in.  Requiring an annotation for a mechanism designed to supersede that mechanism may be viewed as boilerplate.
2. Stored properties with public visibility are often intialized directly with a value provided by the caller.
3. Stored properties with **less visibility** than a memberwise initializer are not eligible for memberwise initialization.  No annotation is required to indicate that and it is usually not desired.
4. The *automatic* model cannot exist unless it is the default.  The *opt-in* model can exist alongside the *automatic* model and itself be opted-into simply by specifying the `memberwise` declaration modifier on one or more properties.

I do think a strong argument can be made that it may be **more clear** to require a `memberwise` declaration modifier on stored properties in order to *opt-in* to memberwise initialization.  

### Allow all initializers to participate in memberwise initialization

This option was not seriously considered.  It would impact existing code and it would provide no indication in the declaration of the initializer that the compiler will synthesize additional parameters and perform additional initialization of stored properties in the body of the initializer.

### Require initializers to opt-out of memberwise initialization

This option was also not seriously considered.  It has the same problems as allowing all initializers to participate in memberwise initialization.

### Allow parameters to be synthesized for properties with a lower access level than the initializer

I considered allowing parameters to be synthesized for properties that are not directly visible to callers of the initializer.  There is no direct conflict with the access modifier and it is possible to write such code manually.  I decided against this approach because as it is unlikely to be the right approach most of the time.  In cases where it is the right approach I think it is a good thing to require developers to write this code manually.

Reasons to limit memberwise parameter synthesis to members which are *at least* as visible as the initializer include:

1. Makes logical sense at first blush.  Memberwise inits publishing private state would be odd/surprising.
2. Safer default, in that you don’t accidentally publish stuff you don’t want through a memberwise init.
3. It is likely the more common desire of the author of an initializer.  If the caller can’t see a member it probably doesn’t make sense to allow them to initialize it.
4. If we expose more private-members by default then memberwise initialization is useless under the current proposal in many cases.  There would be no way to prevent synthesis of parameters for more-private members.  We have to choose between allowing callers to initialize our internal state or forgoing the benefit of memberwise initialization. 
5. If a proposal for `@nomemberwise` is put forward and adopted that would allow us to prevent synthesis of parameters for members as desired.  Unfortunately `@nomemberwise` would need to be used much more heavily than it otherwise would (i.e. to prevent synthesis of memberwise parameters for more-private members).  It would be better if `@nomemberwise` was not necessary most of the time.
6. If callers must be able to provide memberwise arguments for more-private members directly it is still possible to allow that while taking advantage of memberwise initialization for same-or-less-private members.  You just need to declare a `memberwise init` with explicitly declared parameters for the more-private members and initialize them manually in the body.  If the "Access control for init" enhancement is accepted another option would be upgrading the visibility of `init` for the more-private member while retaining its access level for the getter and setter.  Requiring the programmer to explicitly expose a more-private member either via `init` access control or by writing code that it directly is arguably a very good thing.

Reasons we might want to allow memberwise parameter synthesis for members with lower visiblity than the initializer:

1. Not doing so puts tension between access control for stored properties and memberwise inits.  You have to choose between narrower access control or getting the benefit of a memberwise init.  Another way to say it: this design means that narrow access control leads to boilerplate.

NOTE: The tension mentioned here is lessened by #6 above: memberwise initialization can still be used for same-or-less-private members and the requirement to explicitly expose more-private members to more-public initializers one way or another is arguably a good thing.

### Require initializers to explicitly specify memberwise initialization parameters

The thread "[helpers for initializing properties of the same name as parameters](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151130/000428.html)" discussed an idea for synthesizing property initialization in the body of the initializer while requiring the parameters to be declard explicitly.  

```swift
struct Foo {
    let bar: String
    let bas: Int
    let baz: Double
    init(self.bar: String, self.bas: Int, bax: Int) {
		  // self.bar = bar synthesized by the compiler
		  // self.bas = bas synthesized by the compiler
        self.baz = Double(bax)
    }
}

```

The downside of this approach is that it does not address the M x N scaling issue mentioned in the motivation section.  The manual initialization statements are elided, but the boilerplate parameter declarations still grow at the rate MxN (properties x initializers).  It also does not address forwarding of memberwise initialization parameters which makes it useless for convenience and delegating initializers.

Proponents of this approach believe it provides additional clarity and control over the current proposal.  

Under the current proposal full control is still available.  It requires initializers to opt-in to memberwise initialization.  When full control is necessary an initializer will simply not opt-in to memberwise initialization synthesis.  The boilerplate saved in the examples on the list is relatively minimal and is tolerable in situations where full control of initialization is required.

I believe the `memberwise` declaration modifier on the initializer and the placeholder in the parameter list make it clear that the compiler will synthesize additional parameters.  Furthermore, IDEs and generated documentation will contain the full, synthesized signature of the initializer.  

Finally, this idea is not mutually exclusive with the current proposal.  It could even work in the declaration of a memberwise initializer, so long the corresponding property was made ineligible for memberwise intialization synthesis.

### Adopt "type parameter list" syntax like Kotlin and Scala

Several commenters in the mailing list thread have suggested using syntax like Kotlin and Scala that looks like this:

```swift
struct Rect(var origin: Point = Point(), var size: Size = Size()) {}
```

Which would expand to:

```swift
struct Rect {}
  // Whether the initial value is included here or not is unclear.
  // Mailing list suggestions have not included it.
  var origin: Point // = Point()
  var size: Size // = Size()
  init(origin: Point = Point(), size: Size = Size()) {
    self.origin = origin
    self.size = size
  }
```

This approach was not chosen because it is not compatible with the goal of this proposal to provide a flexible and scalable solution for memberwise initialization.  Specific reasons include:

1. This proposal supports partial memberwise initialization.  
	Initializers can receive non-memberwise parameters and can initialize private state manually while still exposing public properties for direct initialization by callers via memberwise initialization.
2. This proposal supports multiple memberwise initializers.
	It may be necessary to support more than one way to initialize private state while still desiring direct initialization of public properties via memberwise initialization.
3. This proposal supports more flexibility for organizing property declarations.
	The Scala / Kotlin syntax may be acceptable in really simple cases.  Unfortunately it requires placing property declarations in a single list at the beginning of the type declaration.  This is extremely limiting.  
	It is especially unfortunatey for types which contain generic parameters and inheritance clauses.  Property declarations would be sandwiched in between those two clauses cluttering up type-level information with member-level information

This proposal is not mutually exclusive with supporting the "type parameter list" syntax.  They are aimed at solving different problems and could live side-by-side.  A future proposal could introduce similar syntax.  One option for such a proposal would be to provide a simple expansion into property declarations, allowing the current proposal to drive synthesis of the initializer (assuming the default parameter values for `let` properties problem is solved by that time). 

In fairness I would like to repeat the advantages of the Scala / Kotlin syntax that have been mentioned:

1. It might support default values for parameters corresponding to `let` properties.
2. It could allow parameter labels to be specified.
3. It is more concise than the current proposal in some cases.

Responses to these points follow:

1. If the expansion of this syntax does not supply initial values to the synthesized properties and only uses the default value for parameters of the synthesized initializer this is true.  The downside of doing this is that `var` properties no longer have an initial value which may be desirable if you write additional initializers for the type.
	I believe we should continue the discussion about default values for `let` properties.  Ideally we can find an acceptable solution that will work with the current proposal, as well as any additional syntactic sugar we add in the future.
2. I don't believe allowing parameter labels for memberwise initialization parameters is a good idea.  Callers are directly initializing a property and are best served by a label that matches the name of the property.  If you really need to provide a different name you can still do so by writing your initializer manually.  With future enhancements to the current proposal you may be able to use memberwise intialization for properties that do not require a custom label while manually initialzing properties that do need one.
3. The Scala / Kotlin syntax is indeed more concise in some cases, but not in all cases.  Under this proposal the example given above is actually more concise than it is with that syntax:

```swift
struct Rect { var origin: Point = Point(), size: Size = Size() }
```
vs
```swift
struct Rect(var origin: Point = Point(), var size: Size = Size()) {}
```

