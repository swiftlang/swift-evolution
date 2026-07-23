# Aliased Span types

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Author 1](https://github.com/swiftdev), [Author 2](https://github.com/swiftdev)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Vision: [Vision Name](https://github.com/swiftlang/swift-evolution/visions/NNNNN.md)
* Roadmap: *if applicable* [Roadmap Name](https://forums.swift.org/...)
* Bug: *if applicable* [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/issues/NNNNN)
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN) or [swiftlang/swift-evolution-staging#NNNNN](https://github.com/swiftlang/swift-evolution-staging/pull/NNNNN)
* Upcoming Feature Flag: *if applicable* `MyFeatureName`
* Previous Proposal: *if applicable* [SE-XXXX](XXXX-filename.md)
* Previous Revision: *if applicable* [1](https://github.com/swiftlang/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

Introduces a family of `Aliased*Span` types that provide the memory safety guarantees of the `Span` family of types, but with looser requirements around the aliasing of pointers, making them suitable for shared memory and interoperability with other languages.

## Motivation

The `Span` family of types, including `Span` (TODO: se number), `MutableSpan` (TODO se number), `OutputSpan` (TODO se number), as well as their `Raw.*Span` counterparts, provide memory-safe access to contiguous memory. Span types provide lifetime safety, ensuring that the memory they reference isn't freed while the span instance is still accessible, as well as bounds safety because all indexed accesses ensure that the indices are within bounds.

### Spans and the Law of Exclusivity

The `Span` family of types depends on Swift's so-called [Law of Exclusivity](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md#the-law-of-exclusivity), which states that if there are two accesses to the same value in memory, both of them must be reads. Therefore, any access that can change the value in memory is known to be the only place that will modify that memory, which unlocks important optimization opportunities while still maintaining memory safety for the values in the memory the reference. Fundamentally, maintaining the Law of Exclusivity requires reasoning about all potential *aliases* of a particular location in memory, i.e., places where there is a reference (or pointer) to that memory that could be used to access the value stored there. Swift maintains the Law of Exclusivity through a mix of language and runtime features. Non-copyable types (like `UniqueArray`, TODO se number) establish unique ownership, whereas non-escapable types (like the `Span` family of types) limit the scope in which data can be accessed, all at compile time. Copy-on-write collections (such as `Array`) and dynamic exclusivity checking (e.g., for global variables) establish exclusivity at run-time for places where it isn't possible to reason about every potential alias. Most of this is invisible to the Swift developer, unless they encounter code that violates the Law of Exclusivity. For example, attempting to create two `MutableSpan` instances that reference into the same `Array`, or modify the `Array` while there is an actual `Span` referencing its storage, will produce a compile-time error about the "overlapping access" that violates exclusivity:

```swift
func f() {
  var array = [1, 2, 3, 4, 5]

  let data = array.span // note: conflicting access is here
  array.append(6) // error: overlapping accesses to 'array', but modification requires 
                  // exclusive access; consider copying to a local variable 
  print(data[0])
}
```

Scenarios involving runtime exclusivity checking are described in more detail in [SE-0176](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md).

The `Span` dependency on the Law of Exclusivity manifests in its API surface. The `subscript` for `Span` uses a `borrow` accessor ([SE-0507](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md)), which provides direct access to the value without requiring the caller to make a copy, which is only safe when the underlying value cannot change. Similarly, `MutableSpan` exclusively references its underlying memory, and it's `subscript` provides a `mutate` accessor to directly reference that memory (including modifing it). The choices here are important semantically, because they make it possible to support spans over non-copyable types, and also for performance, because they avoid the need for extraneous copies of the underlying data.

### Span without the Law of Exclusivity breaks memory safety

Using the `Span` types in places where we have lifetime safety but have not established the Law of Exclusivity can cause memory-safety problems. For example, consider the following code that introduces aliasing issues through `Span` by using unsafe pointers:

```swift
class MyClass {
  var counter = 0
  
  func doSomething(_ body: () -> Void) {
    body()
    counter += 1
  }
}

func aliasingSafetyProblem(buffer: UnsafeMutableBufferPointer<MyClass>) {
  let otherBuffer = buffer
  let span = unsafe buffer.span
  unsafe span[0].doSomething {        // call doesn't adjust reference count
    unsafe otherBuffer[0] = MyClass() // MyClass instance in the doSomething call could be freed here
  }
}
```

Much of the code is marked `unsafe` here, including deriving a span from an unsafe buffer, because the developer needs to reason about both the lifetime and exclusivity of the unsafe pointer. In the next selection, we explore places where it is possible to reason about lifetime but it is not possible or practical to reason about exclusivity.

### Lifetime safety of buffers is useful without the Law of Exclusivity

There are scenarios where the lifetime- and bounds-safety properties of spans are desirable, but it is impossible or impractical to ensure that the memory they reference obeys the Law of Exclusivity. One concrete example is shared memory, where the same region of memory is also accessible by another process or by some other hardware in the system (e.g., a GPU or network controller with direct memory access). One can build an abstraction to ensure that the shared memory's lifetime is correctly managed (e.g., with noncopyable types or classes), but the Law of Exclusivity can never be applied to such memory, because there are, fundamentally, aliases outside of the view of the program that cannot be reasoned about.

Interoperability with the C family of languages is another area where lifetime can be established through conventions, sometimes backed by static analysis. The vision for [optional strict memory safety in Swift](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md#expressing-memory-safe-interfaces-for-the-c-family-of-languages) outlines the use of C attributes to describe memory-safety properties for lifetimes and bounds to enable importing C(++) APIs using pointers as `Span`-based APIs, allowing them to be used safely from Swift. For example, a C++ API like the following

```c
class MyBuffer {
public:
  std::span<const double> getContents() const __attribute__((lifetimebound));
};
```

could have its method imported into Swift as:

```swift
func getContents() -> Span<Double>
```

The `lifetimebound` attribute indicates that the pointer inside the `std::span` will live as long as the `MyBuffer` instance is still alive and hasn't been changed (e.g., via a non-`const` method), which describes the fundamental lifetime safety property. However, it does *not* imply that there are no aliases for that storage that might modify the memory it references: ensuring the lack of aliases would require reasoning about all C and C++ code that might ever have access to that pointer, which is impractical.

For these cases, where we have lifetime information but cannot provide exclusivity, the only suitable types in the Swift standard library are the `Unsafe(Mutable)(Raw)BufferPointer` types. However, these types throw away all aspects of memory safety, so their use is generally discouraged.

## Proposed solution

This proposal introduces the `Aliased*Span` family of types, which are similar in shape to the `Span` family of types, providing lifetime and bounds safety. These types are:

* `AliasedSpan<Element>`: non-mutating access to a contiguous region of memory storing `Element` values
* `AliasedMutableSpan<Element>`: mutating access to a contiguous region of memory storing `Element` `
* `AliasedRawSpan`: non-mutating access to a contiguous region of untyped memory
* `AliasedMutableRawSpan`: mutating access to a contiguous region of untyped memory

The aliased span types are non-escapable, like their span counterparts. However, because the memory they reference is potentially aliased, they do not depend on the Law of Exclusivity. This causes API differences that are small but meaningful. For example:

* The `subscript` operations use `get` and `set` accessors, which require the client to copy out the value on access. This allows a separate alias to replace the value while the original access is ongoing, without making it a memory safety violation. In the previous `aliasingSafetyProblem` example, this means that the object produced by `self[0]` will be copied (i.e., its retain count is increased) for the duration of the call to `doSomething`, so it cannot be deallocated while the closure is executed.
* The aliased span types do not support non-copyable `Element` types, because we cannot do so on top of `get` and `set` accessors.
* The `AliasedMutable*Span` types are copyable: the non-aliased `Mutable*Span` types are non-copyable because that is needed to maintain exclusive access over the storage by preventing aliases. The `AliasedMutable*Span` types can be copied, because they already account for the possibility of aliases.

There is a full set of conversion operations between the various aliased span types and their non-aliased counterparts. It is safe to create an aliased span from its non-aliased counterparts, because the aliased spans make fewer assumptions, so long as the original span cannot be used in a manner that can be undermined by the derived aliased spans. For example, the following API is safe because the underlying storage is already guaranteed not to be mutated by anyone:

```swift
extension Span where Element: Copyable {
  // Retrieve an aliased span referencing the same storage.
  var aliasedSpan: AliasedSpan<Element> { get }
}
```

With mutable spans, we consume the `MutableSpan` to produce the `AliasedMutableSpan`:

```swift
extension MutableSpan where Element: Copyable {
  // Retrieve an aliased mutable span from this mutable span.
  consuming func asAliased() -> AliasedMutableSpan<Element> { }
}
```

this ensures that one cannot try to access the original `MutableSpan` (which assumes exclusivity) while there might be any aliased mutable spans referencing the same storage.

The conversion in the other direction, which produces a span from an aliased span, is fundamentally unsafe, because it requires one to establish that no other aliases exist for the storage. This proposal provides those conversion APIs, but explicitly marks them as `@unsafe`.

## Detailed design

### `AliasedSpan`

`AliasedSpan` provides access to a contiguous buffer of type `Element`. While the `AliasedSpan` type itself cannot change the contents of the buffer, it is possible that other code also has a reference to that memory and can make changes there. The majority of the API mirrors `Span` itself:

```swift
struct AliasedSpan<Element>: ~Escapable, Copyable, BitwiseCopyable {
  @lifetime(immortal)
  init()
    
  var count: Int { get }
  var isEmpty: Bool { get }

  typealias Index = Int
  var indices: Range<Index> { get }
  
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self {
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self

  @safe
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
    
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result where Element: BitwiseCopyable
    
  func isIdentical(to other: Self) -> Bool
  func isTriviallyIdentical(to other: Self) -> Bool
  func indices(of other: borrowing Self) -> Range<Index>?
}

extension AliasedSpan: Sendable where Element: Sendable {}
```

As noted in the Proposed Solution section, the subscripts for `AliasedSpan` use `get` accessors rather than `borrow` accessors to force the caller to copy the result.

```swift
extension AliasedSpan {
  subscript(_ position: Index) -> Element { get }
  subscript(unchecked position: Index) -> Element { get }
}
```

`AliasedSpan` conforms to the `Iterable` protocol. Note that iteration over an `AliasedSpan` is necessarily less efficient than the corresponding `Span`, because the underlying buffer could be aliased and, therefore, mutated during iteration. Therefore, the iterator will get copies of the elements during iteration, and vend a `Span` into those copied elements, much like an `Iterable` conformance for an arbitrary `Sequence`.

```swift 
extension AliasedSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

APIs that involve byte-level access using `AliasedRawSpan` (in place of `RawSpan` for `Span`), but are otherwise unchanged:

```swift
extension AliasedSpan where Element: ConvertibleFromBytes {
  @lifetime(copy bytes)
  init(viewing bytes: AliasedRawSpan)
}

extension AliasedSpan where Element: ConvertibleToBytes {
  var bytes: AliasedRawSpan { get }
}
```

### `AliasedMutableSpan`

The `AliasedMutableSpan` type is the counterpart to `MutableSpan`, allowing mutating of the contents of the buffer it references. The primary difference from `MutableSpan` is that `AliasedMutableSpan` is `Copyable`. This means that a lot of the API surface, while it has roughly the same shape as `MutableSpan`, no longer needs to be consuming.

```swift
struct AliasedMutableSpan<Element>: ~Escapable, Copyable {
  @lifetime(immortal)
  init()
    
  var count: Int { get }
  var isEmpty: Bool { get }

  typealias Index = Int
  var indices: Range<Index> { get }

  /// Retrieving an aliased span from a mutable span is a safe operation,
  /// because both assume they can alias the underlying storage.
  @lifetime(self copy)
  var aliasedSpan: AliasedSpan<Element> { 
    @lifetime(copy self)
    get
  }
}
```

As noted in the Proposed Solution section, the `AliasedMutableSpan` subscript operation uses `get` and `set` accessors, forcing clients to copy the data in and out. Note that the setter is non-mutating, because it does not change the shape of the span, only the contents of the underlying buffer.

```swift
extension AliasedMutableSpan {
  subscript(_ position: Index) -> Element { 
    get 
    nonmutating set 
  }
  subscript(unchecked position: Index) -> Element {
    get
    nonmutating set
  }
}
```

Other element mutation APIs are similarly non-mutating:

```swift
extension AliasedMutableSpan {
  func swapAt(_ i: Index, _ j: Index)
  func swapAt(unchecked i: Index, unchecked j: Index)
  func update(repeating repeatedValue: consuming Element)
}
```

Unsafe accesses to the buffer mirror that of `MutableSpan`, except that none of them are mutating for the same reason:

```swift
extension AliasedMutableSpan {}
  @safe
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
  
  @safe
  func withUnsafeMutableBufferPointer<
    E: Error, Result: ~Copyable
  >(
    _ body: (UnsafeMutableBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
}

extension AliasedMutableSpan where Element: BitwiseCopyable {}
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  @safe
  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```

Similarly for the `extracting` family of operations, which no longer need to be `mutating`:

```swift
extension AliasedMutableSpan {
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self {
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self  
}
```

APIs involving byte-level access relate to `AliasedMutableRawSpan`. There is only a single `mutableBytes` version, because we don't need distinguish between `inout` and `consuming` the way we did with the non-copyable `MutableSpan`. All of the properties copy the `self` dependency, because it's fine to have multiple aliases of the same storage.

```swift
extension AliasedMutableSpan where Element: ConvertibleFromBytes & ConvertibleToBytes {
  /// Convert a raw span to a typed span.
  @lifetime(copy mutableBytes)
  init(mutableBytes: AliasedMutableRawSpan)
}

extension AliasedMutableSpan where Element: ConvertibleToBytes {
  var bytes: RawSpan {
    @lifetime(copy self)
    get
  }
}

extension AliasedMutableSpan where Element: ConvertibleToBytes & ConvertibleFromBytes {
  var mutableBytes: MutableRawSpan {
    @lifetime(copy self)
    get
  }
}
```

As with `AliasedSpan`, `AliasedMutableSpan` conforms to the `Iterable` protocol, but requires a buffer in the iterator to isolate the iteration from changes to the underlying buffer.

```swift
extension AliasedMutableSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

### Conversions to the aliased span types

An aliased span can be created from its corresponding span type. These operations expressed as either properties or methods on the span type to enable chaining, e.g., `span.aliasedSpan.bytes`. `Span` introduces the `aliasedSpan` property:

```swift
extension Span where Element: Copyable {
  /// Retrieve an aliased span referencing the same storage.
  @lifetime(copy self)
  var aliasedSpan: AliasedSpan<Element> { get }
}
```

For the mutable spans, we need to consume the `MutableSpan` to create the first `AliasedMutableSpan`, otherwise accesses to the original `MutableSpan` (which assumes exclusivity) could overlap the `AliasedMutableSpan` instance that is returned (or a copy thereof).

```swift
extension MutableSpan where Element: Copyable {
  // Retrieve an aliased mutable span from this mutable span.
  consuming func asAliased() -> AliasedMutableSpan<Element>
}
```

### Conversions from the aliased span types

A span type can be created from its corresponding aliased span type, but doing so is *always unsafe*. While the aliased span types do provide lifetime and bounds safety, they do not ensure the absence of aliases that could modify the storage, undermining the safety of the span.

```swift
extension AliasedSpan {
  // Retrieving a span from an aliased span is an unsafe operation,
  // because one must ensure that the underlying storage is not
  // modified by any code while the span (or any copy derived from it) is
  // in use.
  @unsafe var span: Span<Element> { get } 
}

extension AliasedMutableSpan {
  // Retrieving a mutable span from an aliased mutable span is an
  // unsafe operation, because one must ensure that the underlying storage
  // and not accessed at all (read or write) while the mutable span is in
  // use.
  @unsafe var mutableSpan: MutableSpan<Element> { mutating get }
}
```

## Source compatibility

Describe the impact of this proposal on source compatibility.  As a
general rule, all else being equal, Swift code that worked in previous
releases of the tools should work in new releases.  That means both that
it should continue to build and that it should continue to behave
dynamically the same as it did before.  Changes that cannot satisfy
this must be opt-in, generally by requiring a new language mode.

This is not an absolute guarantee, and the Language Workgroup will
consider intentional compatibility breaks if their negative impact
can be shown to be small and the current behavior is causing
substantial problems in practice.

For proposals that affect parsing, consider whether existing valid
code might parse differently under the proposal.  Does the proposal
reserve new keywords that can no longer be used as identifiers?

For proposals that affect type checking, consider whether existing valid
code might type-check differently under the proposal.  Does it add new
conversions that might make more overload candidates viable?  Does it
change how names are looked up in existing code?  Does it make
type-checking more expensive in ways that might run into implementation
limits more often?

For proposals that affect the standard library, consider the impact on
existing clients.  If clients provide a similar API, will type-checking
find the right one?  If the feature overloads an existing API, is it
problematic that existing users of that API might start resolving to
the new API?

## ABI compatibility

Describe the impact on ABI compatibility.  As a general rule, the ABI
of existing code must not change between tools releases or language
modes.  This rule does not apply as often as source compatibility, but
it is much stricter, and the Language Workgroup generally cannot allow
exceptions.

The ABI encompasses all aspects of how code is generated for the
language, how that code interacts with other code that has been
compiled separately, and how that code interacts with the Swift
runtime library.  Most ABI changes center around interactions with
specific declarations.  Proposals that do not affect how code is
generated to interact with an external declaration usually do not
have ABI impact.

For proposals that affect general code generation rules, consider
the impact on code that's already been compiled.  Does the proposal
affect declarations that haven't explicitly adopted it, and if so,
does it change ABI details such as symbol names or conventions
around their use?  Will existing code change its dynamic behavior
when running against a new version of the language runtime or
standard library?  Conversely, will code compiled in the new way
continue to run on old versions of the language runtime or standard
library?

For proposals that affect the standard library, consider the impact
on any existing declarations.  As above, does the proposal change symbol
names, conventions, or dynamic behavior?  Will newly-compiled code work
on old library versions, and will new library versions work with
previously-compiled code?

This section will often end up very short.  A proposal that just
adds a new standard library feature, for example, will usually
say either "This proposal is purely an extension of the ABI of the
standard library and does not change any existing features" or
"This proposal is purely an extension of the standard library which
can be implemented without any ABI support" (whichever applies).
Nonetheless, it is important to demonstrate that you've considered
the ABI implications.

If the design of the feature was significantly constrained by
the need to maintain ABI compatibility, this section is a reasonable
place to discuss that.

## Implications on adoption

The compatibility sections above are focused on the direct impact
of the proposal on existing code.  In this section, describe issues
that intentional adopters of the proposal should be aware of.

For proposals that add features to the language or standard library,
consider whether the features require ABI support.  Will adopters need
a new version of the library or language runtime?  Be conservative: if
you're hoping to support back-deployment, but you can't guarantee it
at the time of review, just say that the feature requires a new
version.

Consider also the impact on library adopters of those features.  Can
adopting this feature in a library break source or ABI compatibility
for users of the library?  If a library adopts the feature, can it
be *un*-adopted later without breaking source or ABI compatibility?
Will package authors be able to selectively adopt this feature depending
on the tools version available, or will it require bumping the minimum
tools version required by the package?

If there are no concerns to raise in this section, leave it in with
text like "This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility."

## Future directions

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

Describe alternative approaches to addressing the same problem.
This is an important part of most proposal documents.  Reviewers
are often familiar with other approaches prior to review and may
have reasons to prefer them.  This section is your first opportunity
to try to convince them that your approach is the right one, and
even if you don't fully succeed, you can help set the terms of the
conversation and make the review a much more productive exchange
of ideas.

You should be fair about other proposals, but you do not have to
be neutral; after all, you are specifically proposing something
else.  Describe any advantages these alternatives might have, but
also be sure to explain the disadvantages that led you to prefer
the approach in this proposal.

You should update this section during the pitch phase to discuss
any particularly interesting alternatives raised by the community.
You do not need to list every idea raised during the pitch, just
the ones you think raise points that are worth discussing.  Of course,
if you decide the alternative is more compelling than what's in
the current proposal, you should change the main proposal; be sure
to then discuss your previous proposal in this section and explain
why the new idea is better.

## Acknowledgments

If significant changes or improvements suggested by members of the 
community were incorporated into the proposal as it developed, take a
moment here to thank them for their contributions. Swift evolution is a 
collaborative process, and everyone's input should receive recognition!

Generally, you should not acknowledge anyone who is listed as a
co-author or as the review manager.
