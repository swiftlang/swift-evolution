# Introduce User-defined "Dynamic Member Lookup" Types

* Proposal: [SE-NNNN](NNNN-DynamicMemberLookup.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Review Manager: TBD
* Implementation: [PR13076](https://github.com/apple/swift/pull/13076)
* Status: **Pending Review**

## Introduction

This proposal introduces a new `DynamicMemberLookupProtocol` type to the standard
library.  Types that conform to it provide "dot" syntax for arbitrary names which are resolved
at runtime.  It is simple syntactic sugar which allows the user to write:

```swift
    a = someValue.someMember
    someValue.someMember = a
    mutateParameter(&someValue.someMember)
````

and have it be interpreted by the compiler as:

```swift
  a = someValue[dynamicMember: "someMember"]
  someValue[dynamicMember: "someMember"] = a
  mutateParameter(&someValue[dynamicMember: "someMember"])
```

Many other languages have analogous features (e.g. the composition of Objective-C's
[explicit properties](https://developer.apple.com/library/content/documentation/General/Conceptual/DevPedia-CocoaCore/DeclaredProperty.html) and underlying [messaging infrastructure](https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtHowMessagingWorks.html)).  This sort
of functionality is great for implementing dynamic language interoperability, dynamic
[proxy APIs](https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtForwarding.html), and other APIs (e.g. for JSON processing).

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation and Context

Swift is well known for being exceptional at interworking with existing C and Objective-C
APIs, but its support for calling APIs written in scripting languages like Python, Perl, and Ruby
is quite lacking.

C and Objective-C are integrated into Swift by expending a heroic amount of effort into
integrating Clang ASTs, remapping existing APIs in an attempt to feel "Swifty", and by
providing a large number of attributes and customization points for changing the behavior
of this integration when writing an Objective-C header. The end result of this massive
investment of effort is that Swift provides a *better* experience when programming against
these legacy APIs than Objective-C itself did.

When considering the space of dynamic languages, three things are clear: 1) there are several
different languages of interest, and they each have significant interest in different quarters:
for example, Python is big in data science and machine learning, Ruby is popular for building
server side apps, a few people apparently use Javascript, and even Perl is in still widely used.
2) These languages have decades of library building behind them, sometimes with [significant
communities](https://pandas.pydata.org) and 3) there are one or two orders of magnitude
more users of these libraries than there are people currently using Swift.

While it is theoretically possible to expend the same level of effort on each of these languages
and communities as has been spent on Objective-C, it is quite clear that this would both
ineffective as well as bad for Swift: It would be ineffective, because the Swift community has
no leverage over these communities to force auditing and annotation of their APIs.  It would
be bad for Swift because it would require a ton of language-specific support (and a number
of third-party dependencies) of the compiler and runtime, each of which makes the
implementation significantly more complex, difficult to reason about, difficult to maintain, and
difficult to test the supported permutations.  In short, we'd end up with a mess.

Fortunately for us, these scripting languages provide an extremely dynamic programming
model where almost everything is discovered at runtime, and many of them are explicitly
designed to be embedded into other languages and applications.  This aspect allows us to
embed APIs from these languages directly into Swift with [no language support at
all](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171113/041463.html) -
without the level of effort, integration, and invasiveness that Objective-C has benefited
from.  Instead of invasive importer work, we can write some language-specific Swift APIs,
and leave the interop details to that library.

This offers a significant opportunity for us - the Swift community can "embrace" these
dynamic language APIs (making them directly available in Swift) reducing the pain of
someone moving from one of those languages into Swift.  It is true that the APIs thus
provided will not feel "Swifty", but if that becomes a significant problem for any one API, then
the community behind it can evaluate the problem and come up with a solution (either a Swift
wrapper for the dynamic language, or a from-scratch Swift reimplementation of the desired
API).  In any case, if/when we face this challenge, it will be a good thing: we'll know that
we've won a significant new community of Swift developers.

While it is possible today to import (nearly) arbitrary dynamic language APIs into Swift today,
the resultant API is unusable for two major reasons: member lookup is too verbose to be
acceptable, and calling behavior is similarly too verbose to be acceptable.  As such, we seek
to provide two "syntactic sugar" features that solve this problem.  These sugars are
specifically designed to be independent of the dynamic languages themselves and, indeed,
independent of dynamic languages at all: we can imagine other usage for the same primitive
capabilities.

The two proposals in question are the introduction of the
[`DynamicCallable`](https://gist.github.com/lattner/a6257f425f55fe39fd6ac7a2354d693d)
protocol and a related `DynamicMemberLookupProtocol` proposal (this proposal).  With
these two extensions, we think we can eliminate the need for invasive importer magic by
making interoperability with dynamic languages ergonomic enough to be acceptable.

For example, consider this Python code:

```Python
class Dog:
    def __init__(self, name):
        self.name = name
        self.tricks = []    # creates a new empty list for each dog

    def add_trick(self, trick):
        self.tricks.append(trick)
```

we would like to be able to use this from Swift like this (the comments show the
corresponding syntax you would use in Python):

```swift
  // import DogModule
  // import DogModule.Dog as Dog    // an alternate
  let Dog = Python.import(“DogModule.Dog")

  // dog = Dog("Brianna")
  let dog = Dog("Brianna")

  // dog.add_trick("Roll over")
  dog.add_trick("Roll over")

  // dog2 = Dog("Kaylee").add_trick("snore")
  let dog2 = Dog("Kaylee").add_trick("snore")
```

Of course, this would also apply to standard Python APIs as well.  Here is an example
working with the Python `pickle` API and the builtin Python function `open`:

```swift
  // import pickle
  let pickle = Python.import("pickle")

  // file = open(filename)
  let file = Python.open(filename)

  // blob = file.read()
  let blob = file.read()

  // result = pickle.loads(blob)
  let result = pickle.loads(blob)
```

This can all be expressed today as library functionality written in Swift, but without this
proposal, the code required is unnecessarily verbose and gross. Without it (but *with* the
related [`DynamicCallable` proposal](https://gist.github.com/lattner/a6257f425f55fe39fd6ac7a2354d693d)
the code would have explicit member lookups all over the place:

```swift
  // import pickle
  let pickle = Python.get(member: "import")("pickle")

  // file = open(filename)
  let file = Python.get(member: "open")(filename)

  // blob = file.read()
  let blob = file.get(member: "read")()

  // result = pickle.loads(blob)
  let result = pickle.get(member: "loads")(blob)

  // dog2 = Dog("Kaylee").add_trick("snore")
  let dog2 = Dog("Kaylee").get(member: "add_trick")("snore")
```

While this is a syntactic sugar proposal, we believe that this expands Swift to be usable in
important new domains.  In addition to dynamic language interoperability, this sort of
functionality is useful for other APIs, e.g. when working with dynamically typed unstructured
data like JSON, which could provide an API like `jsonValue?.jsonField1?.jsonField2`
where each field is dynamically looked up.  An example of this is shown below in the
"Example Usage" section.

## Proposed solution

We propose introducing a new protocol to the standard library:

```swift
/// Types type conform to this protocol have the behavior that member lookup -
/// accessing `someval.member` will always succeed.  Failures to find normally
/// declared members of `member` will be turned into subscript references using
/// the `someval[dynamicMember: member]` member.
///
public protocol DynamicMemberLookupProtocol {
  // Implementations of this protocol must have a subscript(dynamicMember:)
  // implementation where the keyword type is some type that is
  // ExpressibleByStringLiteral.  It can be get-only or get/set which defines
  // the mutability of the resultant dynamic properties.

  // subscript<KeywordType: ExpressibleByStringLiteral, LookupValue>
  //   (dynamicMember name: KeywordType) -> LookupValue { get }
}
```

It also extends the language such that member lookup syntax (`x.y`) - when it otherwise fails
(because there is no member `y` defined on the type of `x`) and when applied to a value which
conforms to `DynamicMemberLookupProtocol` - is accepted and
transformed into a call to the subscript in the protocol.  The produced value is a mutable
L-value if the type conforming to `DynamicMemberLookupProtocol` implements a mutable
subscript, or immutable otherwise.  This allows the type to perform arbitrary runtime
processing to calculate the value to return.  The dynamically computed property can be used
the same way as an explicitly declared computed property, including being passed `inout`.

The protocol is intentionally designed to be flexible: the implementation can take the member
name through any `ExpressibleByStringLiteral` type, including `StaticString` and of
course `String`.  The result type may also be any type the implementation desires, including
an `Optional`, which allows the implementation to reflect dynamic failures in a way the user
can be expected to process (e.g., see the JSON example below).

This protocol is implemented as a "marker protocol" which enables the magic name lookup
behavior, but does not have any explicitly declared requirements within its body.  This is
because Swift's type system doesn't have the ability to directly express the requirements we
have: consider that subscripts can have mutating getters and nonmutating setters.  These
are important to support, because it affects when and if values may be get and set through
a potentially immutable base type.  Alternative implementation approaches were explored,
and are discussed in the "Alternatives Considered" section below.

## Example Usage

While there are many potential uses of this sort of API one motivating example comes from a
prototype
Python interoperability layer.  There are many ways to implement this, and the details are not
particularly important, but it is perhaps useful to know that this is directly useful to address
the motivation section described above.   Given a currency type of PyVal (and a conforming
implementation named `PyRef`), an implementation may look like:

```swift
extension PyVal : DynamicMemberLookupProtocol {
  subscript(dynamicMember member: String) -> PyVal {
    get {
      let result = PyObject_GetAttrString(borrowedPyObject, member)!
      return PyRef(owned: result)
    }
    set {
      PyObject_SetAttrString(borrowedPyObject, member,
                             newValue.borrowedPyObject)
    }
  }
}
```

Another example use are JSON libraries which represent JSON blobs as a Swift enum, e.g.:

```swift
enum JSON {
  case IntValue(Int)
  case StringValue(String)
  case ArrayValue(Array<JSON>)
  case DictionaryValue(Dictionary<String, JSON>)
}
```

Today, it is not unusual for them to implement members like this to allow drilling down into
the JSON value:

```swift
extension JSON {
  var stringValue : String? {
    if case .StringValue(let str) = self {
      return str
    }
    return nil
  }
  subscript(index: Int) -> JSON? {
    if case .ArrayValue(let arr) = self {
      return index < arr.count ? arr[index] : nil
    }
    return nil
  }
  subscript(key: String) -> JSON? {
    if case .DictionaryValue(let dict) = self {
      return dict[key]
    }
    return nil
  }
}
```

This allows someone to drill into a JSON value with code like:
`json[0]?["name"]?["first"]?.stringValue`.  On the other hand, if we add a simple
conformance to `DynamicMemberLookupProtocol` like this:

```swift
extension JSON : DynamicMemberLookupProtocol {
  subscript(dynamicMember member: String) -> JSON? {
    if case .DictionaryValue(let dict) = self {
      return dict[member]
    }
    return nil
  }
}
```

Now clients are able to write more natural code like:
`json[0]?.name?.first?.stringValue` which is close to the expressivity of Javascript...
while being fully type safe!


## Source compatibility

This is a strictly additive proposal with no source breaking changes.

## Effect on ABI stability

This is a strictly additive proposal with no ABI breaking changes.

## Effect on API resilience

Types that conform to this protocol will always succeed at member lookup (`x.foo` will
always be accepted by the compiler): members that are explictly declared in the type or in
a visible extension will be found and referenced, and anything else will be handled by the
dynamic lookup feature.

That behavior could lead to a surprising behavior change if the API evolves over time: adding
a new staticly declared member to the type or an extension will cause clients to resolve that
name to the static declaration instead of being dynamically dispatched.  This is inherent to
this sort of feature, and means it should not be used on types that have a large amount of
API, API that is likely to change over time, or API with names that are likely to conflict.

## Alternatives considered

A few alternatives were considered:

### Declare an explicit subscript requirement

We considered (and tried very hard) to declare an explicit `subscript` requirement inside the
protocol, but ran into several problems:

First, we seek to support both get-only and get/set dynamic
properties.  If we tried to reflect these capabilities into the type system, we'd end up
with two protocols: `DynamicMemberLookupProtocol` and
`MutableDynamicMemberLookupProtocol`.  This expands the surface area of the proposal,
and would make the implementation more complicated.

Second, recall that getters and setters can be both mutating and nonmutating.  We definitely
need the ability to represent that, but could choose to either reflect that in the requirement
signature (dramatically expanding the number of protocols) or not (make the requirement be
mutating for both, but allow an implementation to have a stricter implementation).  Both
options could work, but neither is great.

Third, the natural way to express the subscript requirement is with associated types, perhaps
something like this (using the simplest get-only case to illustrate the point):

```swift
protocol DynamicMemberLookupProtocol {
  associatedtype DynamicMemberLookupKeyword : ExpressibleByStringLiteral
  associatedtype DynamicMemberLookupValue
  subscript(dynamicMember name: DynamicMemberLookupKeyword)
    -> DynamicMemberLookupValue { mutating get }
}
```

However, if we go this approach, then this marker protocol is now a "Protocol with
Associated Type" (PAT) which (among other things) prevents protocols that further refine the
protocol from being usable as existentials - Swift does not yet support [Generalized
Existentials](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#generalized-existentials),
and probably will not until Swift 6 at the earliest.  This also pollutes the type with the two
associated type names.

The other attempted way to implement this was with a generic subscript, like this:

```swift
protocol DynamicMemberLookupProtocol {
  subscript<DynamicMemberLookupKeywordType: ExpressibleByStringLiteral,
            DynamicMemberLookupValue>
    (dynamicMember name: DynamicMemberLookupKeywordType)
        -> DynamicMemberLookupValue { mutating get }
}
```

This fixes the problem with PATs, but has the distinct disadvantage that it is impossible to
fulfill the subscript requirement with a concrete (non-generic) subscript implementation.

### Model this with methods, instead of a labeled subscript

It may be surprising to some that this functionality is modeled as a subscript instead of a
get/set method pair.  This is intentional though: subscripts are the way that Swift supports
parameterized l-values like we're are trying to expose here.  Exposing this as two methods
doesn't fit into the language as cleanly, and would make the compiler implementation more
invasive and crazy.

### Naming

Suggestions for a better name for the protocol and the subscript (along with rationale to
support them) are more than welcome.

On naming of `subscript(dynamicMember:)`, we intentionally gave it a long and verbose
names so they stay out of the way of user code completion.  The members of this protocol
are really just compiler interoperability glue.  If there was a Swift attribute to disable the
subscript from showing up in code completion, we would use it (such an attribute would
also be useful for the `LiteralConvertible` and other compiler magic protocols).

