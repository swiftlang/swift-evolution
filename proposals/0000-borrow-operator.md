# Feature name

* Proposal: [SE-NNNN](NNNN-borrow-operator.md)
* Authors: [John McCall](https://github.com/rjmccall)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Vision: [Ownership](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md)
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN)
* Upcoming Feature Flag: *if applicable* `MyFeatureName`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Borrowing a value allows it to be used without copying it, which can
be good for performance. Swift can often perform borrows implicitly,
but sometimes it's useful to be able to force the issue. This proposal
adds a `borrow` operator that explicitly requests a borrow to be done,
causing an error if a borrow is not possible in this situation.

## Motivation

Many of the following concepts were first explained in the old
[ownership manifesto](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md#core-definitions). As Swift has added features
from that document, our understanding of some of these concepts has
changed, and the terms we've used for them has changed as well.
I'll start by restating the definitions from the manifesto using
modern terminology.

An *high-level value* is our human understanding of the information
content of the result of an expression. The expression `[1,2,3]`
creates an array of three integers. After the following code runs,
the variables `a` and `b` hold the same high-level values because
they currently contain the same information.

```swift
var a = [1, 2, 3]
var b = a
```

The variable `c` has this same high-level value, even though the
value is constructed completely independently:

```swift
var c = [1]
c += [2, 3]
```

A *low-level value* is one step down in abstraction level. `a`, `b`, and `c`
all store different low-level values. If we carefully read the standard
library source code, we can see that a low-level value of type `Array<Int>`
is an owned reference to an array buffer object. The low-level value in `b`
was produced by copying the low-level value in `a`. Copying an owned object reference produces a new owned reference to the same object, so these two
values now refer to the same buffer. However, they are still different
low-level values because they each have independent ownership of a
reference to that object.

That ownership is one of the most important components of these low-level
values, and it is intangible --- it cannot be directly observed. If you
inspected this program's memory in a debugger, you might be able to see
that the reference count of the array buffer object referenced by `a` and
`b` is 2, but you would not see that the variables have responsibility for
a single reference count apiece. An unowned reference to that object might
look the same in memory, but it would not have the same responsibility.[^1]

[^1]: Swift's `unowned` references are memory-safe, so in fact they do still
have a responsibility to manage the object, it's just a *different*
responsibility from an owned reference. `unowned(unsafe)` references are
irresponsible, which is why they're unsafe.

If we went another step down in abstraction level, we would need to get into
*representations* of values and how they are laid out in memory. But in this
proposal, we are concerned with ownership, which mostly operates at the level
of low-level values. So we do not need to talk about representations, and
we will just talk about low-level values.

For the rest of this proposal, the word *value* by itself should be understood
to mean this low-level concept in which copying a value produces a new value.

Every use of a value in Swift has some interaction with ownership.
Non-mutating uses of values are always either:

- *borrows*, which just read the low-level information in the value, or
- *copies*, which create a new, independent copy of that low-level
  information according to the rules of the type.

Swift decides whether to borrow or copy a value based on how it is used
and where it comes from. As a general rule, borrowing a value is less
expensive and is always preferable when possible. The costs of copying
values does not always matter, but sometimes they can come to dominate a
time or memory profile, and it becomes important to find ways to avoid
them. 

In some situations, Swift cannot borrow a value because it will be used
in an operation that requires an independent value, such as assigning
it into a variable. These copies generally cannot be avoided by
transferring ownership of an existing value, such as with the [`consume`
operator][SE-0366]. This proposal does not help with this.

In other cases, a value could theoretically be borrowed from where it
is stored in memory, but Swift instead chooses to emit a *conservative
copy*. In general, Swift does this in order to avoid conflicts if some
other code modifies that location while the value is in use. If the
programmer is sure that such a conflict is impossible, borrowing the
value instead would avoid the copy. However, it can be tricky to
convince Swift to actually do this today because there is no feature
to explicitly request it.

Swift does have some features for avoiding implicit copies of borrowed
values. For example, under [SE-0377][], you can declare a parameter as
`borrowing`:

```swift
func total(_ array: borrowing [Int]) -> Int {
  ...
}
```

Within this function, Swift will not implicitly copy the value of this
parameter. However, this does not prevent the *caller* of this function
from potentially having copied the value before passing it in:

```swift
let sum = total(c)
```

Swift will make a local decision when compiling this call about whether
it is necessary to conservatively copy the value. In the simple case of
a local variable, Swift should be able to guarantee that `c` will be
borrowed by proving that `c` is not modified during the call. But if
`c` were a global variable, or a class property, this would be difficult,
and Swift is likely to emit a conservative copy.[^2]

[^2]: The presence of `borrowing` on the function parameter does not
affect this decision. If it did, adopting `borrowing` would change the
semantics of all calls to the function, potentially causing them to
experience conflicts that they did not before. The authors of SE-0377
justly wanted the modifier to have only local effects.

## Proposed solution

This proposal adds a new `borrow` operator that explicitly requires a
value to be borrowed for a particular use.

```swift
// Force the value of c to be borrowed. If c is somehow modified during
// this call, there may be an error at runtime.
let sum = total(borrow c)
```

It is an error if it is not possible to borrow the value.

## Detailed design

`borrow` is a contextual keyword, parsed as an operator when it is used
at the start of an expression. This precludes most other uses of the
identifier without backticks.

```text
borrow-operator ::= 'borrow'                          // contextual

prefix-expression ::= borrow-operator? prefix-operator? postfix-expression
```

`borrow` must be written after "marker" keyword operators such
as `try` and `await`. These operators can normally span sequences of
binary operators, but `borrow` cannot and applies to a single expression
result. To avoid any confusion from this, `borrow` must be written last,
e.g. as `try borrow x` rather than as `borrow try x`. (This restriction
is also implicit in the grammar rule above.)

The use of the `borrow` operator represents a request to force the value
of the expression to which it is applied to be borrowed (rather than used
in any other way) for its use in the position in which it appears. As a
general rule, if there is any reason why this is not possible and the
`borrow` operator cannot be meaningfully honored, the code should be
rejected rather than dynamically performing the copy, even if the reason
is technically obscure.[^3]

[^3]: Thus, for example, a copy that is forced by value reabstraction or
explosion/implosion must still be rejected, even though these might be hard
to explain to most programmers. Fortunately, these problems are restricted
to the use of tuple and function values.

This rule is largely consistent with `borrow` expressions being forbidden
from appearing in certain syntactic positions:

- A `borrow` expression cannot be the outermost expression in a statement.

- A `borrow` expression cannot be used as the operand of a *mutating
  operation*:
  - the first operand of the `=` assignment operator, or an element of
    a tuple literal expression that appears in such a position, recursively;
  - any call or subscript argument that is passed `inout`, including the
    first operand of a user-defined assignment operator, the operand of
    the `&` inout expression, and the object expression of a `mutating`
    method call; or
  - the base expression of a property reference or subscript expression
    that, as accessed, requires a mutating access to the base.

- A `borrow` expression cannot be used as the operand of a *consuming
  operation*[^4]:

  - the initializer expression in a binding declaration, including the
    binding of an `if let` or `guard let`;
  - the subject of a copying or consuming `switch` (not applicable here);
  - the operand of a `return` statement;
  - the operand of the `consume` operator;
  - the operand of the `try?` operator;
  - the final step in a `?` optional chain (not applicable here)
  - the second or third operand of the `?` ternary operator;
  - the second operand of the `=` assignment operator;
  - an element of a tuple literal expression that is not the first operand
    of the `=` operator, recursively;
  - a component of an array or dictionary literal expression;
  - any call or subscript argument that is passed `consuming`, including
    `init` parameters that are not explicitly `borrowing` and the object
    expression of a `consuming` method call; or
  - the base expression of a property reference of subscript expression
    that, as accessed, requires a consuming access to the base.

[^4]: This definition is meant to supersede the definition in [SE-0390][],
which is why it includes several entries that are impossible for the borrow
operator, such as non-borrowing `switch`es (a `switch` is by definition
a borrowing switch if the operand is a borrow expression) and optional
chains (which cannot end in a `borrow` operator grammatically). Note the
addition since SE-0390 of the literal expressions, which are self-evidently
consuming, and of `try?`. `try?` must be consuming because its result
is not always the result of its operand, and Swift does not permit
borrows to be conditionally derived from different control flow paths.

The operand of a `borrow` expression must be a *borrowable expression*.
Currently, the only kind of borrowable expression is a storage reference
expression whose storage declaration [guarantees borrowing read
access](#guaranteed-borrowable).

The above restrictions are syntactic checks that look through:
- parentheses;
- the value-preserving marker expressions `try`, `try!`, `await`, and `unsafe`; and
- the variadic-generic `repeat` operator.

<a name="guaranteed-borrowable"></a>

### Storage declarations that guarantee borrowing read access

In order to be borrowed from, a storage declaration must guarantee the
ability to perform a borrowing read access.

To permit source-compatible and binary-compatible library evolution,
this is a module-sensitive definition. Typically, the client module
is the module containing the code that uses the storage declaration.
However, in `@inlinable` function definitions, the client module is
a notional module that is able to call the function but is otherwise
maximally unprivileged: an arbitrary module in a different package
for `public` or `open` declarations, or an arbitrary module in the
same package for `package` declarations.

A storage declaration guarantees borrowing read access if it provides
borrowing read access and has a stable interface with respect to
the client module.

A storage declaration guarantees borrowing read access if:
- it is a stored variable or property,
- it is defined with a borrowing read accessor[^5], or
- it is the special `subscript(keyPath:)`.[^6]

[^5]: There are not yet any official borrowing read accessors in Swift,
but the unofficial `_unsafeAddress` and `_read` accessors are both
considered to be borrowing reads, as is the `read` accessor from
[this recent pitch](https://forums.swift.org/t/pitch-modify-and-read-accessors/75627).

[^6]: A key path access may have to copy dynamically, depending on the
implementation of the storage declarations along the actual path.
A `borrow` is nonetheless allowed as a request for the access to make
its best effort to borrow, and it should reliably borrow if all
components are stored. Because `borrow` has a meaningful effect when
the property is in fact borrowable, this dynamic behavior is considered
acceptable. It would be impossible to provide a static guarantee without
a new dimension of `KeyPath` subclasses that are restricted to borrowable
key paths, which is unrealistic to consider. 

Several properties and subscripts in the standard library guarantee
borrowing read access:
- **TODO**: provide a list of operations with this guarantee

A storage declaration has a stable interface with respect to the client
module if:
- it has a *universally stable interface* or
- the client module is in the same package as the module the defines
  the storage declaration.

A storage declaration has a universally stable interface if:
- its defining module has a stable binary interface or is part of the
  Swift standard library, and
- the storage declaration is either
  - a protocol requirement,
  - `@inlinable`, or
  - a stored property of a `@frozen` type.

Unfortunately, Swift has not yet settled on a way for ordinary source
libraries to provide a stable interface.

### Borrowing pattern matches

When the subject of a `switch`, `if case`, or `guard case` is a
`borrow` expression, the pattern matching becomes borrowing as described
in [SE-0432][].

### Base expressions of borrowed properties and subscripts

To avoid any surprising needs for redundant `borrow` operators in a
single expression, conservative copies are also suppressed for the
result of any expression that the operand is *postfix-derived from*:

- the base expression of a member reference, including an implicit
  access to `self`;
- the base expression of a subscript;
- the operand of postfix `!`;
- the function expression of a call; or
- the sub-expression any of the value-preserving expressions listed above,
  such as parentheses.

For example:

```swift
var array: [String] = ...

// This borrows both the value of the subscript and the value of
// `array` itself, since it is possible to borrow a value from `array`
// and a borrowing read of Array.subscript requires only non-mutating
// access to the array, which can be implemented with a borrow.
use(string: borrow array[0])
```

This rule suppresses only *conservative* copies, which is to say that it
does not have the same strong borrowing guarantee for nested positions
as a direct use of the borrow operator would have.

For example, if the array can only be accessed via a `get` accessor,
it is not possible to borrow, and so this indirect propagation of `borrow`
has no effect on it:

```swift
var computedArray: [String] {
  get { return array }
}

// This is invalid because it is not possible to borrow the
// value of `computedArray`.
use(string: (borrow computedArray)[0])

// Therefore, this borrows only the value of the subscript, and the
// operator has no effect on the access to `computedArray`.
use(string: borrow computedArray[0])
```

Similarly, this indirect propagation has no effect when a base expression
of borrowed storage must be accessed with `mutating` or `consuming`
semantics:

```swift
struct MutatingArray<Element> {
  subscript(index: Int) -> Element {
    mutating _read {
      ...
    }
  }
}

var mutatingArray: MutatingArray<String> = ...

// This is invalid because there is a mutating access to `mutatingArray`.
use(string: (borrow array)[0])

// Therefore, this borrows only the value of the subscript, and the operator
// has no effect on the access to `mutatingArray`.
use(string: borrow array[0])

final class ContainsMutatingArray {
  var mutatingArray: MutatingArray<String>
}
var cma: ContainsMutatingArray = ...

// This borrows both the value of the subscript and the value of `cma`,
// but the operator has no effect on the mutating access to
// `cma.mutatingArray`.
use(string: borrow cma.mutatingArray[0])
```

These rules only apply to expressions in the main postfix sequence and
does not affect e.g. call or subscript arguments that appear within it.

Code that wishes to force a copy of a particular sub-expression may use
the `copy` operator or simply assign it to a new `let`.

## Source compatibility

This proposal claims a new context-sensitive keyword in a way that
essentially prevents its normal use as a function name. Unfortunately,
because the operand can be an arbitrary storage reference expression,
it is difficult to imagine how this could be made to coexist with e.g.
existing `borrow()` calls. Such calls are also likely to be highly
confusing.

**TODO**: do an investigation to see how much of a problem this actually is

## ABI compatibility

This feature does not affect binary interfaces.

Borrows are only allowed on binary-stable declaration if their
implementation is frozen and guarantees the ability to borrow.

## Implications on adoption

There are no adoption concerns for using the `borrow` operator in
your own code and on your own storage declaration. However, there
are ecosystem concerns which this proposal has made an effort to
sidestep, with some unfortunate (if hopefully temporary) consequences.

It is fairly well-known that Swift has a longstanding source-
compatibility problem with `enum` switch exhaustiveness: clients
can easily write exhaustive switches over enums from their
dependencies, causing them to break if they pull a new version that
adds more cases. This is one instance of a more general problem
around defining what, exactly, counts as the interface of a
declaration. Some features are inherently sensitive to details of
an implementation that a maintainer may reasonably wish to evolve:

- Exhaustive switching is sensitive to the complete set of cases
  in an `enum`, so we have compatibility problems with it.

- The memberwise initializer is sensitive to the complete set of
  stored properties in a `struct`, so we'd have compatibility
  problems with it if we didn't make it `internal` by default.

Unfortunately, the `borrow` operator is sensitive to whether
you can borrow from storage, which means it can distinguish
a stored property (which can always be borrowed from) from a
`get`/`set` property (which cannot).

The right solution to this problem is that libraries should have a
way to indicate that some aspect of the implementation is locked down.
Clients of source-distributed packages should not be able to
rely on those details otherwise, just as clients of binary-distributed
libraries cannot rely on details that are not guaranteed in the ABI.
It's not entirely clear what this should look like, however.

Since Swift does not have such a capability, this proposal takes a
hardline stance preventing cross-package borrows entirely unless the
target is binary-compatible. This is quite unfortunate, but it's
better than taking the switch exhaustiveness problem and making it
apply to every stored property in the source-distributed ecosystem.

## Future directions

### Permit `borrow` in local `let` bindings

The syntax `let x = borrow y` is forbidden by the rules described
above, but it would reasonable to allow it in local contexts as a
way of forming a borrowed local binding. This would permit functions
to extract a value and use it repeatedly in a local scope without
needing to either copy it or engage in circumlocutions like the
following:

```swift
{ borrowing x in
  ...
}(borrow y)
```

### Guarantee borrows in more situations

Swift's use of conservative copies by default is [an intentional
choice](#borrow-by-default). However, there are many situations where
Swift could reasonably guarantee to borrow by default

Describe any interesting proposals that could build on this proposal
in the future.  This is especially important when these future
directions inform the design of the proposal, for example by making
sure an attribute encodes enough information to be used for other
purposes.

The rest of the proposal should generally not talk about future
directions except by referring to this section.  It is important
not to confuse reviewers about what is covered by this specific
proposal.  If there's a larger vision that needs to be explained
in order to understand this proposal, consider starting a discussion
thread on the forums to capture your broader thoughts.

Avoid making affirmative statements in this section, such as "we
will" or even "we should".  Describe the proposals neutrally as
possibilities to be considered in the future.

Consider whether any of these future directions should really just
be part of the current proposal.  It's important to make focused,
self-contained proposals that can be incrementally implemented and
reviewed, but it's also good when proposals feel "complete" rather
than leaving significant gaps in their design.  For example, when
[SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md)
introduced the `@inlinable` attribute, it also included the
`@usableFromInline` attribute so that declarations used in inlinable
functions didn't have to be `public`.  This was a relatively small
addition to the proposal which avoided creating a serious usability
problem for many adopters of `@inlinable`.

## Alternatives considered

<a name="borrow-by-default"></a>

### Never conservatively copy by default

Swift's decision to conservatively copy in some situations is a deliberate
choice, which it makes to reduce friction and surprise in traditional
object-oriented programming patterns.

The memory safety design used by languages like Swift and Rust relies
on local static reasoning about how memory is used. We say that memory
is "aliased" when there are different contexts in the program with the
ability to make conflicting accesses to it. When memory is not aliased,
the language has a lot of power to ensure both safety and performance.
But when memory is abstracted over in a less structured way, there is
an inherent trade-off between safety, performance, and simplicity /
lack of surprise.

It is very easy to simply ignore the dangers of aliasing. C and C++
freely allow pointers to memory to be created and passed around
without making any effort to ensure that only one context uses them
at once. A function that receives a pointer (or C++ reference) can
make no assumptions about what other code might be doing with it.
This is, of course, completely unsafe.

To provide memory safety, languages have two choices: they can
statically prevent aliasing, or they can perform dynamic checks to
try to establish the safety at runtime. Rust and Swift both do both,
but they make different choices.

Memory-safe languages generally aim to guarantee that there aren't
*concurrent* uses of the same memory that can possibly conflict. This
is because it's challenging to make any meaningful guarantees about
either memory behavior or safety in the presence of data races. This
is true even for single-core preemptive concurrency, but the widespread
introduction of truly parallel multi-core machines over the last twenty
years has driven it home. Therefore, when we're worried about conflicting
accesses to memory, we're mostly worried about *reentrancy*: we're
worried that we will call something while we're accessing memory, and
that code will access the same memory in a conflicting way.

One consequence of this is that copying values is a reliable way to
eliminate aliasing. If you need access to the value in some memory
location, you know that nothing else is accessing that location *right
now*, so you can just copy the current value in it. At this point, you
no longer have to worry about any subsequent changes to the location,
because you have your own independent copy of the value. This would not
work if there were concurrent conflicts uses of the memory, but those are
by definition data races, and we've already agreed that we have to
eliminate those.

Value-oriented programming in languages like Swift and Rust generally
doesn't have a problem with reentrant memory conflicts because values
are not prone to aliasing. A function's caller might pass down an
immutable value borrowed from memory (e.g. a Swift borrow or a Rust
`&`), but the function has no way of "reversing" that to find the
memory and then generating a conflicting access to it. To cause a
conflict, the function must have some other path to that memory, and
that just can't happen with pure values --- the path must pass through
some kind of shared state, like a global variable or a shared reference.
So this tends to only come up in particular programming paradigms:
most importantly, traditional reference-semantics object-oriented
programming, where programs often contain a lot of opaque abstractions
and triggered behavior.

These kinds of programming paradigms are prone to surprising dynamic
behavior precisely because of the ubiquitous aliasing they rely on.
Swift's basic design philosophy is that that's okay. The language does
its best to deliver a simple memory-safe experience anyway, and it just
might have some performance compromises. For example, rather than trying
to statically enforce exclusivity for shared mutable memory like class
properties, Swift enforces it with [dynamic checks][SE-0176]. Our choice
to conservatively copy from such memory by default instead of borrowing
is in line with that decision. If we borrowed by default, we would
be much more prone to triggering dynamic exclusivity failures in these
cases of reentrancy.

Rust takes a stronger stand against doing dynamic checks for builtin
features. You can still write this style of code in Rust, but you must
use library types like `Rc<RefCell<T>>` or `Arc<Mutex<T>>` that use
dynamic checks instead of static enforcement, and the coarseness
of the checking does make violations more likely if you make
arbitrary work within the protected blocks.

## Acknowledgments

This proposal builds on prior work by Joe Groff and Andrew Trick.

[SE-0176]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md
[SE-0366]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0366-move-function.md
[SE-0377]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md
[SE-0390]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md
[SE-0432]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0432-noncopyable-switch.md