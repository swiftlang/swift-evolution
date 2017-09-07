# Make unsafe pointer nullability explicit using Optional

* Proposal: [SE-0055](0055-optional-unsafe-pointers.md)
* Author: [Jordan Rose](https://github.com/jrose-apple)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000086.html)
* Implementation: [apple/swift#1878](https://github.com/apple/swift/pull/1878)

## Introduction

In Objective-C, pointers (whether to objects or to a non-object type) can be
marked as `nullable` or `nonnull`, depending on whether the pointer value can
ever be null. In Swift, however, there is no such way to make this distinction
for pointers to non-object types: an `UnsafePointer<Int>` might be null, or it
might never be.

We already have a way to describe this: Optionals. This proposal makes
`UnsafePointer<Int>` represent a non-nullable pointer, and
`UnsafePointer<Int>?` a nullable pointer. This also allows us to preserve
information about pointer nullability available in header files for imported
C and Objective-C APIs.

swift-evolution thread: <https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012918.html>


## Motivation

Today, UnsafePointer and friends suffer from a problem inherited from C: every
pointer value could potentially be null, and code that works with pointers may
or may not expect this. Failing to take the null pointer case into account can
lead to assertion failures or crashes. For example, pretty much every operation
on UnsafePointer itself requires a valid pointer (reading, writing, and
initializing the `pointee` or performing arithmetic operations).

Fortunately, when a type has a single invalid value for which no operations are
valid, Swift already has a solution: Optionals. Applying this to pointer types
makes things very clear: if the type is non-optional, the pointer will never be
null, and if it *is* optional, the developer must take the "null pointer" case
into account. This clarity has already been appreciated in Apple's Objective-C
headers, which include nullability annotations for all pointer types (not just
object pointers).

This change also allows developers working with pointers to take advantage of
the many syntactic conveniences already built around optionals. For example,
the standard library currently has a helper method on UnsafeMutablePointer
called `_setIfNonNil`; with "optional pointers" this can be written simply and
clearly:

    ptr?.pointee = newValue

Finally, this change also reduces the number of types that conform to
NilLiteralConvertible, a source of confusion for newcomers who (reasonably)
associate `nil` directly with optionals. Currently the standard library
includes the following NilLiteralConvertible types:

- Optional
- ImplicitlyUnwrappedOptional (subject of a separate proposal by Chris Willmore)
- _OptionalNilComparisonType (used for `optionalValue == nil`)
- *UnsafePointer*
- *UnsafeMutablePointer*
- *AutoreleasingUnsafeMutablePointer*
- *OpaquePointer*

plus these Objective-C-specific types:

- *Selector*
- *NSZone* (only used to pass `nil` in Swift)

All of the italicized types would drop their conformance to
NilLiteralConvertible; the "null pointer" would be represented by a nil
optional of a particular type.


## Proposed solution

1. Have the compiler assume that all values with pointer type (the italicized
   types listed above) are non-null. This allows the representation of
   `Optional.none` for a pointer type to be a null pointer value.

2. Drop NilLiteralConvertible conformance for all pointer types.

3. Teach the Clang importer to treat `_Nullable` pointers as Optional (and
   `_Null_unspecified` pointers as ImplicitlyUnwrappedOptional).

4. Deal with the fallout, i.e. adjust the compiler and the standard library to
   handle this new behavior.

5. Test migration and improve the migrator as necessary.

This proposal does not include the removal of the NilLiteralConvertible
protocol altogether; besides still having two distinct optional types, we've
seen people wanting to use `nil` for their own types (e.g. JSON values).
(Changing this in the future is not out of the question; it's just out of scope
for this proposal.)


## Detailed design


### API Changes

- Conformance to NilLiteralConvertible is removed from all types except
  Optional, ImplicitlyUnwrappedOptional, and _OptionalNilComparisonType, along
  with the implementation of `init(nilLiteral:)`.

- `init(bitPattern: Int)` and `init(bitPattern: UInt)` on all pointer types
  become failable; if the bit pattern represents a null pointer, `nil` is
  returned.

- Should [SE-0016][] be accepted, the `init(bitPattern:)` initializers on Int
  and UInt will be changed to take optional pointers.

- New initializers will be added to all pointer types to convert between
  optional pointer types (see below).

- UnsafeBufferPointer's `baseAddress` property becomes nullable, along with its
  initializer parameter (see below).

- `Process.unsafeArgv` is a pointer to a null-terminated C array of C strings,
  so its type changes from `UnsafeMutablePointer<UnsafeMutablePointer<Int8>>` to
  `UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>`, i.e. the inner pointer
  type becomes optional.

- NSErrorPointer becomes optional:

````diff
-public typealias NSErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>
+public typealias NSErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?
````

- A number of methods on String that came from NSString now have optional
  parameters:

````diff
   public func completePathIntoString(
-    outputName: UnsafeMutablePointer<String> = nil,
+    outputName: UnsafeMutablePointer<String>? = nil,
     caseSensitive: Bool,
-    matchesIntoArray: UnsafeMutablePointer<[String]> = nil,
+    matchesIntoArray: UnsafeMutablePointer<[String]>? = nil,
     filterTypes: [String]? = nil
   ) -> Int {
````

````diff
   public init(
     contentsOfFile path: String,
-    usedEncoding: UnsafeMutablePointer<NSStringEncoding> = nil
+    usedEncoding: UnsafeMutablePointer<NSStringEncoding>? = nil
   ) throws {

   public init(
     contentsOfURL url: NSURL,
-    usedEncoding enc: UnsafeMutablePointer<NSStringEncoding> = nil
+    usedEncoding enc: UnsafeMutablePointer<NSStringEncoding>? = nil
   ) throws {
````

````diff
   public func linguisticTags(
     in range: Range<Index>,
     scheme tagScheme: String,
     options opts: NSLinguisticTaggerOptions = [],
     orthography: NSOrthography? = nil,
-    tokenRanges: UnsafeMutablePointer<[Range<Index>]> = nil
+    tokenRanges: UnsafeMutablePointer<[Range<Index>]>? = nil
   ) -> [String] {
````

- NSZone's no-argument initializer is gone. (It probably should have been
  removed already as part of the Swift 3 naming cleanup.)

- A small regression: optional pointers can no longer be passed using
  `withVaList` because it would require a conditional conformance to the
  CVarArg protocol. For now, using `unsafeBitCast` to reinterpret the optional
  pointer as an Int is the best alternative; Int has the same C variadic
  calling conventions as a pointer on all supported platforms.

[SE-0016]: 0016-initializers-for-converting-unsafe-pointers-to-ints.md

### Conversion between pointers

Currently each pointer type has initializers of this form:

````swift
init<OtherPointee>(_ otherPointer: UnsafePointer<OtherPointee>)
````

This simply makes a pointer with a different type but the same address as
`otherPointer`. However, in making pointer nullability explicit, this now only
converts non-nil pointers to non-nil pointers. In my experiments, this has led
to this idiom becoming very common:

````swift
// Before:
let untypedPointer = UnsafePointer<Void>(ptr)

// After:
let untypedPointer = ptr.map(UnsafePointer<Void>.init)

// Usually the pointee type is actually inferred:
foo(ptr.map(UnsafePointer.init))
````

I consider this a bit more difficult to understand than the original code, at
least at a glance. We should therefore add new initializers of the following
form:

````swift
init?<OtherPointee>(_ otherPointer: UnsafePointer<OtherPointee>?) {
  guard let nonnullPointer = otherPointer else {
    return nil
  }
  self.init(nonnullPointer)
}
````

The body is for explanation purposes only; we'll make sure the actual
implementation does not require an extra comparison.

(This would need to be an overload rather than replacing the previous
initializer because the "non-null-ness" should be preserved through the type
conversion.)

Note: It is very likely the existing initializers described here will be
renamed (perhaps to `init(bitPattern:)`). In this case, the new initializers
should adopt the same argument labels.


### UnsafeBufferPointer

The type `UnsafeBufferPointer` represents a bounded typed memory region with no
ownership or lifetime semantics; it is made up of a bare typed pointer (its
`baseAddress`) and a length (`count`) and conforms to `Collection`. There is
also a variant with mutable contents named `UnsafeMutableBufferPointer`.

For a buffer with 0 elements, there's no need to provide the address of
allocated memory, since it can't be read from. This case is represented as a
`nil` base address and a count of 0.

With this proposal, the `baseAddress` property becomes optional:

````diff
   /// Construct an Unsafe${Mutable}Pointer over the `count` contiguous
   /// `Element` instances beginning at `start`.
-  public init(start: Unsafe${Mutable}Pointer<Element>, count: Int) {
+  ///
+  /// If `start` is nil, `count` must be 0. However, `count` may be 0 even for
+  /// a nonzero `start`.
+  public init(start: Unsafe${Mutable}Pointer<Element>?, count: Int) {
````

````diff
-  public var baseAddress: Unsafe${Mutable}Pointer<Element> {
+  public var baseAddress: Unsafe${Mutable}Pointer<Element>? {
````

This does force clients using `baseAddress` to consider the possibility that
the buffer does not represent allocated memory. However, we believe that most
clients are either using the Collection conformance and ignoring the
`baseAddress` property, or are immediately passing the pointer (and perhaps
also the count) to a C API, most of which accept null pointers with a 0 count.
In either case a null pointer should be treated no differently from any other
address with a count of 0. This API also allows converting to and from a pair
of `(UnsafePointer?, Int)` without losing information and without needing to
explicitly handle the nil case.

> Here is some data on standard library uses of UnsafeBuffer:
>
> - Used as Collection: 4 (mostly String operations)
> - Passed to C-style APIs (pointer and length): 1
> - Explicitly extracting the base address: 3 (all related to C strings)
>
> A "use" here is roughly "mentioned at least once in a function body".


## Impact on existing code

Any code that uses a pointer type (including Selector or NSZone) may be
affected by this change. For the most part our existing logic to handle last
year's nullability audit should cover this, but the implementer should test
migration of several projects to see what issues might arise.

> Anecdotally, in migrating the standard library to use this new logic I've been
> quite happy with nullability being made explicit. There are many places where
> a pointer really *can't* be nil.


## Alternatives considered

The primary alternative here would be to leave everything as it is today, with
`UnsafePointer` and friends including the null pointer as one of their normal
values. This has obviously worked just fine for nearly two years of Swift, but
it is leaving information on the table that can help avoid bugs, and is strange
in a language that makes fluent use of Optional. As a fairly major
source-breaking change, it is also something that we probably should do sooner
rather than later in the language's evolution.

Félix Cloutier also noted that this may prove problematic for porting Swift to
a platform where there are no invalid pointer values (usually an embedded
platform). However, Chris Lattner thinks this potential future issue should not
limit the improvements that can be made to Swift today (especially given the
lack of several other features necessary for low-level system programming, such
as `volatile`), and Doug Gregor pointed out that Clang and LLVM have the
assumption that "0 is an invalid pointer" hardcoded in many places already.
This is not an entirely satisfactory answer, but I agree that we should go
ahead with the language change regardless.


### Alternatives for UnsafeBufferPointer

The chosen API change for UnsafeBufferPointer does impose a cost on clients
that want to access and use the base address themselves: they need to consider
the `nil` case explicitly, where previously they wouldn't have had to. We
considered several alternatives, including:

- Using an arbitrary address with proper alignment whenever we would have used
  `nil` as a base address.

- Eliminating `nil` from the `withUnsafeBufferPointer` APIs and then making
  the `baseAddress` property non-optional; clients that need to deal with `nil`
  could use an Optional UnsafeBufferPointer.

The ultimate consensus (both on the list and in off-list discussion with the
Swift core team) was that neither of these behave well when using
UnsafeBufferPointer to interoperate with C APIs, even if we could make
`withUnsafeBufferPointer`. We *do* eliminate the possibility of using the type
system to distinguish between "buffers that may have a null base address" and
"buffers known to have a non-null base address", but we're expecting that
distinction to not be a useful one anyway.
