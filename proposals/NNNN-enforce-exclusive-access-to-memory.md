# Enforce Exclusive Access to Memory

* Proposal: [SE-NNNN][NNNN-enforce-exclusive-access-to-memory.md]
* Authors: [John McCall][https://github.com/rjmccall]
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

In Swift 3, it is possible to modify a variable while it's being used or
modified by another part of the program.  This can lead to unexpected and
confusing results.  It also forces a great deal of conservatism onto the
implementation of the compiler and the standard libraries, which must
generally ensure the basic soundness of the program (no crashes or
undefined behavior) even in unusual circumstances.

We propose that Swift should instead enforce a general rule that potential
modifications of variables must be exclusive with any other access to that
variable.

This proposal is a core part of the Ownership feature, which was described
in the [ownership manifesto](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md).
That document presents the high-level objectives of Ownership, develops
a more rigorous theory of memory access in Swift, and applies it in detail
to a variety of different language features.  In that document, the rule
we're proposing here is called the Law of Exclusivity.  We will not be
going into that level of detail in this proposal.  Instead, we will
lay out the basic rule, how it will be enforced, and the implications for
programming in Swift.  It should be possible to understand this proposal
without actually having read the ownership manifesto at all.  That said,
if you are interested in the technical details, that document is probably
the right place to turn.

## Motivation

### Instantaneous and non-instantaneous accesses

On a basic level, Swift is an imperative language which allows programmers
to directly access mutable memory.

Many of the language features that access memory, like simply loading
from or assigning to a variable, are "instantaneous".  This means that,
from the perspective of the current thread, the operation completes
without any other code being able to interfere.  For example, when you
assign to a stored property, the current value is just replaced with
the new value.  Because arbitrary other code can't run during an
instantaneous access, it's never possible for two instantaneous accesses
to overlap each other (without introducing concurrency, which we'll
talk about later).  That makes them very easy to reason about.

However, not all accesses are instantaneous.  For example, when you
call a ``mutating`` method on a stored property, it's really one long
access to the property: ``self`` just becomes another way of referring
to the property's storage.  This access isn't instantaneous because
all of the code in the method executes during it, so if that code
manages to access the same property again, the accesses will overlap.
There are several language features like this already in Swift, and
Ownership will add a few more.

Here's an example:

```swift
// These are simple global variables.
var global: Int = 0
var total: Int = 0

extension Int {
  // Mutating methods access the variable they were called on
  // for the duration of the method.
  mutating func increaseByGlobal() {
    // Any accesses they do will overlap the access to that variable.
    total += self
    self += global

    // If the accesses happen to be to the same variable that the
    // method was called on, the results can be very difficult to
    // reason about.  How does the behavior of this method change
    // if it's called on 'global'?  On 'total'?

    // In this example, we've made the potentially-overlapping
    // accesses obvious, but they don't have to be.  For example,
    // this method could take a closure as an argument.  We don't
    // know what code that closure will execute, and therefore
    // we don't know what variables it will access.  We could have
    // overlaps even if this method is invoked on a local variable!
  }
}
```

### Eliminating non-instantaneous accesses?

If non-instantaneous accesses create all of these problems with
overlapping accesses, should we just eliminate non-instantaneous
accesses completely?  Well, no, and there's two big reasons why not.
In order to make something like a ``mutating`` method not access
the original storage of ``self`` for the duration of the method,
we would need to make it access a temporary copy instead, which
we would assign back to the storage after the method is complete.
That is, suppose we had the following Swift code:

```swift
var numbers = [Int]()
numbers.appendABunchOfStuff()
```

Currently, behind the scenes, this is implemented somewhat like
the following C code:

```c
struct Array numbers = _Array_init();
_Array_appendABunchOfStuff(&numbers);
```

You can see clearly how ``_Int_appendABunchOfStuff`` will be working
directly with the storage of ``numbers``, creating the abstract
possibility of overlapping accesses to that variable.  To prevent
this in general, we would need to pass a temporary copy instead:

```c
struct Array numbers = _Array_init();
struct Array temp = _Array_copy(numbers);
_Array_appendABunchOfStuff(&temp);
_Array_assign(&numbers, temp);
```

Like we said, there's two big problems with this.

The first problem is that it's awful for performance.  Even for a
normal type, doing extra copies is wasteful, but doing it with ``Array``
is even worse because it's a copy-on-write type.  The extra copy here
means that there will be multiple references to the buffer, which
means that ``_Array_appendABunchOfStuff`` will be forced to copy the
buffer instead of modifying it in place.  Removing these kinds of
copies, and making it easier to reason about when they happen, is a
large part of the goal of the Ownership feature.

The second problem is that it doesn't even eliminate the potential
confusion.  Suppose that ``_Array_appendABunchOfStuff`` somehow
reads or writes to ``numbers`` (perhaps because ``numbers`` is
captured in a closure, or it's actually a global variable or a class
property or something else that can be potentially accessed from
anywhere).  Because the method is now modifying the copy in ``temp``,
any reads it makes from ``numbers`` won't see any of the changes
it's made to ``temp``, and any changes it makes to ``numbers`` will
be silently lost when it returns and the caller unconditionally
overwrites ``numbers`` with ``temp``.

### Consequences of non-instantaneous accesses

So we have to live with non-instantaneous accesses.  That means
programmers can write code that would naturally cause overlapping
accesses to the same variable.  What does this mean for programming
in Swift?

In Swift 3, we simply allow the overlapping accesses to happen, and we
try to live with the consequences.  In general, this translates to a
lot of complexity and lost performance.

For example, the ``Array`` type has an optimization in its ``subscript``
operator which allows callers to directly access the storage of array
elements.  This is a very important optimization which, among other
things, allows arrays to efficiently hold values of copy-on-write types.
However, because the caller can execute arbitrary code while they're
working with the array element storage, and that code might do something
like assign a new value to the original array variable and therefore drop
the last reference to the array buffer, this optimization has to create a
new strong reference to the buffer until the caller is done with the element,
which itself causes a whole raft of complexity.

Similarly, when the compiler is optimizing a ``mutating`` method, it has
to assume that an arbitrary call might completely rewrite ``self``.
This makes it very difficult to perform any meaningful optimization
at all, especially in generic code.  It also means that the compiler
must generally emit a large number of conservative copies just in case
things are modified in unexpected ways.

Furthermore, the possibility of overlapping accesses has a continued
impact on language evolution.  Many of the features laid out in the
Ownership manifesto rely on static guarantees that Swift simply cannot
make without stronger rules about when a variable can be modified.

Therefore we think it best to simply disallow overlapping accesses
as best as we can.

## Proposed solution

We should add a rule to Swift that two accesses to the same variable
are not allowed to overlap unless both accesses are reads.  By
"variable", we mean any kind of mutable memory: global variables,
local variables, class and struct properties, and so on.

This rule should be enforced as strongly as possible, depending on
what sort of variable it is:

* Local variables and struct properties can generally enforce the
  rule statically.  The compiler can analyze all the accesses to the
  variable and emit an error if it sees any conflicts.

* Class properties and global variables will have to enforce the
  rule dynamically.  The runtime can keep track of what accesses
  are underway and report any conflicts.  Local variables will
  sometimes have to use dynamic enforcement when they are
  captured in closures.

* Unsafe pointers will not use any active enforcemnet; it is the
  programmer's responsibility to follow the rule.

* No enforcement is required for immutable memory, like a ``let``
  binding or property, because all accesses must be reads.

## Detailed design

### Concurrency

Swift has always considered read/write and write/write races on
the same variable to be undefined behavior which it is the
programmer's responsibility to eliminate.  That does not change
under this proposal.  Specifically, dynamic enforcement is not
required to detect concurrent accesses to storage.  Our hope is
that this will permit dynamic enforcement to be sufficiently
efficient to be enabled by default.

Any future concurrency design in Swift will have the elimination
of such races as a primary goal.  To the extent that it succeeds,
it will also define away any specific problems for exclusivity.

### Value types

Calling a method on a value type is an access to the entire value:
a write if it's a ``mutating`` method, a read otherwise.  This is
because we have to assume that a method might read or write an
arbitrary part of the value.  Trying to formalize rules like
"this method only uses these properties" would massively complicate
the language.

For similar reasons, using a computed property or subscript on a
value type generally has to be treated as an access to the entire
value.  Whether the access is a read or write depends on how the
property/subscript is used and whether either the getter or the setter
is ``mutating``.

Accesses to different stored properties of a ``struct`` or different
elements of a tuple are allowed to overlap.  However, note that
modifying part of a value type still requires exclusive access to
the entire value, and that acquiring that access might itself prevent
overlapping accesses.  For example:

```swift
struct Pair {
  var x: Int
  var y: Int
}

class Paired {
  var pair = Pair(x: 0, y: 0)
}

let object = Paired()
swap(&object.pair.x, &object.pair.y)
```

Here, initiating the write-access to ``object.pair`` for the first
argument will prevent the write-access to ``object.pair`` for the
second argument from succeeding because of the dynamic enforcement
used for the property.  Attempting to make dynamic enforcement
aware of the fact that these accesses are modifying different
elements of the property would be prohibitive.

However, this limitation can be worked around by binding
``object.pair`` to an ``inout`` argument:

```swift
func modifying<T>(_ value: inout T, _ function: (inout T) -> ()) {
  function(&value)
}

modifying(&object.pair) { pair in swap(&pair.x, &pair.y) }
```

This works because now there is only a single access to
``object.pair`` and because ``inout`` arguments use purely
static enforcement.

We expect that workarounds like this will only rarely be required.

Note that two different properties can only be assumed to not
conflict when they are both known to be stored.  This means that,
for example, it will not be allowed to have overlapping accesses
to different properties of a resilient value type.  This is not
expected to be a significant problem for programmers.

### Arrays

Collections do not receive any special treatment in this proposal.
For example, ``Array``'s indexed subscript is an ordinary computed
subscript on a value type.  Accordingly, mutating an element of an
array will require exclusive access to the entire array, and
therefore will disallow any other simultaneous accesses to the
array.

It's always been somewhat fraught to do simultaneous accesses to
an array because of copy-on-write.  The fact that you should not
create an array and then fork off a bunch of threads that assign
into different elements concurrently has been independently
rediscovered by a number of different programmers.  The main
new limitation here is that some idioms which did work on a
single thread are going to be forbidden.  This may just be a
cost of progress.

In the long term, the API of ``Array`` and other collections
should be extended to ensure that there are good ways of achieving
the tasks that exclusivity enforcement has made difficult.
It will take experience living with exclusivity in order to
understand the problems and propose the right API additions.
In the short term, these problems can be worked around with
``withUnsafeMutableBufferPointer``.

We do know that swapping two array elements will be problematic,
and accordingly we are separately proposing to add a ``swap``
method to ``MutableCollection`` that takes two indices rather
than two ``inout`` arguments.

### Class properties

Unlike value types, accesses to different stored properties of
reference types are always tracked independently.  Accessing a
property on a class reference never prevents overlapping accesses
to different properties.

### Disabling dynamic enforcement.

We should add an attribute which allows dynamic enforcement to
be downgraded to an unsafe-pointer-style undefined-behavior rule
on a variable-by-variable basis.  This will allow programmers to
opt out of the expense of dynamic enforcement when it is known
to be unnecessary (e.g. because exclusivity is checked at some
higher level) or when the performance burden is simply too great.

Since the rule still applies, and it's merely no longer being checked,
it makes sense to borrow the "checked" and "unchecked" terminology
from the optimizer settings.

```swift
class TreeNode {
  @exclusivity(unchecked) var left: TreeNode?
  @exclusivity(unchecked) var right: TreeNode?
}
```

## Source compatibility

In order to gain the performance and language-design benefits of
exclusivity, we will have to enforce it in all language modes.
Therefore, exclusivity will eventually demand a source break.

We can mitigate some of the impact of this break by implicitly migrating
code matching certain patterns to use different patterns that are known
to satisfy the exclusivity rule.  For example, it would be straightforward
to automatically translate calls like ``swap(&array[i], &array[j])`` to
``array.swap(i, with: j)``.  Whether this makes sense for any particular
migration remains to be seen; for example, ``swap`` does not appear to be
used very often in practice outside of specific collection algorithms.

Overall, we do not expect that a significant amount of code will violate
exclusivity.  This has been borne out so far by our testing.  Often the
examples that do violate exclusivity can easily be rewritten to avoid
conflicts.  In some of these cases, it may make sense to do the rewrite
automatically to avoid source-compatibility problems.

## Effect on ABI stability and resilience

In order to gain the performance and language-desing benefits of
exclusivity, we must be able to assume that it is followed faithfully
in various places throughout the ABI.  Therefore, exclusivity must be
enforced before we commit to a stable ABI, or else we'll be stuck with
the current conservatism around ``inout`` and ``mutating`` methods
forever.
