# Rename `sizeof` and related functions to comply with API Guidelines

* Proposal: [SE-0101](0101-standardizing-sizeof-naming.md)
* Author: [Erica Sadun](http://github.com/erica)
* Status: **Scheduled for review June 21...27**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Upon accepting [SE-0096](https://github.com/apple/swift-evolution/blob/master/proposals/0096-dynamictype.md), the core team renamed the proposed stdlib function from `dynamicType()` to `type(of:)` to better comply with Swift's API guidelines.
This proposal renames `sizeof`, `sizeofValue`, `strideof`, `strideofValue`, `align`, and `alignOf` to emulate SE-0096's example.

Swift Evolution Discussion: [\[Pitch\] Renaming sizeof, sizeofValue, strideof,	strideofValue](http://thread.gmane.org/gmane.comp.lang.swift.evolution/19459)

[Earlier](http://thread.gmane.org/gmane.comp.lang.swift.evolution/15830)

## Motivation

Swift's API guidelines indicate that free-standing functions without side-effects should be named using a noun describing the returned value. 

* Although `sizeof()`, etc are treated as terms of art, these names are appropriated from C. The functions do not correspond to anything named `sizeof` in LLVM. 
* All names are expanded to be more explanatory by prefixing `memory` and adopting lower camel case. Names are more often read than written, and the proposed names are more self-documenting.
* As `stride` already has a well-established meaning in the standard library, this proposal changes its name to `interval`, matching existing documentation.
* Via API guidance, `align` is renamed to `alignment`. 
* SE-0096's `type(of:)` signature operates on instances. This aligns it with `sizeofValue`, `alignofValue`, `strideofValue`, which operate on instances. Using `of` rather than `ofValue` matches this behavior but at the cost of clarity. This proposal recommends amending SE-0096 to change `type(of:)` to `type(ofValue:)`.
* Improving type-call usability should take precedence over instance-calls. (See next bullet point.) Although `function(ofType:)` offers a natural correspondence to SE-0096, this proposal recommends omitting a label to enhance readability. `memorySize` should be clear enough (and noun enough) to mitigate any issues of whether the name is or is not a noun.
* As the following chart shows, type-based calls consistently outnumber instance-based calls in gist, github, and stdlib searches. The Google search for `sizeof` is probably too general based on its use in other languages.

<table>
<tr width = 800>
<th width = 200>Term</td>
<th width = 150>stdlib search</td>
<th width = 150>gist search</td>
<th width = 150>Google site:github.com swift</td>
</tr>
<tr width = 800>
<td width = 200>sizeof</td>
<td width = 150>157</td>
<td width = 150>169</td>
<td width = 150>(18,600, term is probably too general)</td>
</tr>
<tr width = 800>
<td width = 200>sizeofValue</td>
<td width = 150>4</td>
<td width = 150>34</td>
<td width = 150>584</td>
</tr>
<tr width = 800>
<td width = 200>alignof</td>
<td width = 150>44</td>
<td width = 150>11</td>
<td width = 150>334</td>
</tr>
<tr width = 800>
<td width = 200>alignofValue</td>
<td width = 150>5</td>
<td width = 150>5</td>
<td width = 150>154</td>
</tr>
<tr width = 800>
<td width = 200>strideof</td>
<td width = 150>24</td>
<td width = 150>19</td>
<td width = 150>347</td>
</tr>
<tr width = 800>
<td width = 200>strideofValue</td>
<td width = 150>1</td>
<td width = 150>5</td>
<td width = 150>163</td>
</tr>
</table>

**Note:** There is a [known bug](https://lists.swift.org/pipermail/swift-dev/Week-of-Mon-20160530/002150.html) (cite D. Gregor) that does not enforce `.self` when used with `sizeof`, allowing `sizeof(UInt)`. This call should be `sizeof(UInt.self)`. This proposal is written as if the bug were resolved without relying on adoption of [SE-0090](https://github.com/apple/swift-evolution/blob/master/proposals/0090-remove-dot-self.md).

## Detailed Design

```swift
/// Returns the contiguous memory footprint of `T`.
///
/// Does not include any dynamically-allocated or "remote" storage.
/// In particular, `memorySize(X.self)`, when `X` is a class type, is the
/// same regardless of how many stored properties `X` has.
public func memorySize<T>(_: T.Type) -> Int

/// Returns the contiguous memory footprint of  `T`.
///
/// Does not include any dynamically-allocated or "remote" storage.
/// In particular, `memorySize(of: a)`, when `a` is a class instance, is the
/// same regardless of how many stored properties `a` has.
public func memorySize<T>(ofValue: T) -> Int

/// Returns the least possible interval between distinct instances of
/// `T` in memory.  The result is always positive.
public func memoryInterval<T>(_: T.Type) -> Int

/// Returns the least possible interval between distinct instances of
/// `T` in memory.  The result is always positive.
public func memoryInterval<T>(ofValue: T) -> Int

/// Returns the minimum memory alignment of `T`.
public func memoryAlignment<T>(_: T.Type) -> Int

/// Returns the minimum memory alignment of `T`.
public func memoryAlignment<T>(ofValue: T) -> Int
```

### Design Notes

**Labels**: This design omits labels for types. It uses `ofValue` for values, assuming SE-0096 would update to match. This proposal recommends matching SE-0096 regardless of the core team decision.

**Using Autoclosure**: It may make sense to use `@autoclosure` for value variants as the call shouldn't need its arguments evaluated:

```swift
public func memorySize<T>(ofValue _: @autoclosure T -> ()) -> Int
public func memoryInterval<T>(ofValue _: @autoclosure T -> ()) -> Int
public func memoryAlignment<T>(ofValue _: @autoclosure T -> ()) -> Int
```

**Accepting Type Variations**: The core team may choose omit the value variants entirely, replacing just three freestanding functions and removing the other three. In doing so, users must call `type` on passed values. This pattern is already found in standard library code.

Current code:
```swift
let errnoSize = sizeof(errno.dynamicType)
```

Updated code:
```swift
let errnoSize = memorySize(type(ofValue:errno))
```

Pyry Jahkola points out one instance where the `memorySize(type(of: …))` workaround won't work. When the value is an existential, it's illegal to ask for the size of its dynamic type: the result can't be retrieved at compile time:

```swift
// Swift 2.2, 64-bit
let i = 123
print(sizeofValue(i)) //=> 8
let c: CustomStringConvertible = i
print(sizeofValue(c)) //=> 40
print(sizeof(c.dynamicType)) // error: cannot invoke 'sizeof' with an argument list of type '(CustomStringConvertible.Type)'
```

On the other hand, dropping the `ofValue:` variations allows SE-00096 to remain unamended.


## Impact on Existing Code

This proposal requires migration support to rename keywords that use the old 
convention to adopt the new convention. This is a simple substitution with 
limited impact on existing code that is easily addressed with a fixit.

## Alternatives Considered

Dave Abrahams suggested rather than using global functions, the following design be considered:

```swift
MemoryLayout<T>.size // currently sizeof()
MemoryLayout<T>.spacing // currently strideof()
MemoryLayout<T>.alignment // currently alignof()
```

Dave further recommends that `sizeofValue()`, `strideofValue()`, and `alignofValue()` be completely removed from Swift. Usage numbers from code searches (see above table) support his stance on their value, as instance types can be easily retrieved using `type(of:)`.  It is possible to use Dave's design and to retain value functions, as Matthew Johnson and Pyry Jahkola have laid out in on-list discussions.

#### Why not `MemoryLayout`

In the rare times users consume memory layout functionality, using a MemoryLayout type reduces clarity. Consider the following examples, taken from Swift 3.0 stdlib files:

```swift
let errnoSize = sizeof(errno.dynamicType)
return sizeof(UInt) * 8
sendBytes(from: &address, count: sizeof(UInt.self))
_class_getInstancePositiveExtentSize(bufferClass) == sizeof(_HeapObject.self)
bytesPerIndex: sizeof(IndexType)
```

The proposed rewrite for these are:

```swift
let errnoSize = memorySize(ofValue: errno)
return memorySize(UInt.self) * 8
sendBytes(from: &address, count: memorySize(UInt.self))
_class_getInstancePositiveExtentSize(bufferClass) == memorySize(_HeapObject.self)
bytesPerIndex: memorySize(IndexType.self)
```

versus

```swift
let errnoSize = MemoryLayout.init(t: errno).size
return MemoryLayout<UInt>.size * 8
sendBytes(from: &address, count: MemoryLayout<UInt>.size)
_class_getInstancePositiveExtentSize(bufferClass) == MemoryLayout<_HeapObject.self>.size
bytesPerIndex: MemoryLayout<IndexType>.size
```

Swift adheres to a mantra of clarity. In each of the preceding examples, calling a function produces simpler code than using the Memory Layout approach:

* *Early mention of the requested information*: In functions the name (size, spacing/interval, alignment) are stated earlier, supporting reading code in one pass from left to right. Using properties delays recognition and causes the reader longer mental processing times.
* *Simplicity of the function call*: Calls devote the entirety of their name to describing what they do.
* *Prominence of the type constructor*: The eye is drawn to the MemoryLayout pattern. Using full type specification lends calls an importance and verbosity they don't deserve compared to their simpler counterparts.

## Acknowledgements

Thank you, Xiaodi Wu, Matthew Johnson, Pyry Jahkola, Tony Allevato, Joe Groff, Dave Abrahams, and everyone else who contributed to this proposal