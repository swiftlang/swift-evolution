# Feature name

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-consistent-NSError-bridging-at-language-boundary.md)
* Author(s): [Charles Srstka](https://github.com/CharlesJS)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

This proposal is for NSError objects presented by Objective-C APIs to be bridged
to native Swift value types, similar to how NSString currently is bridged to String.
This would involve creating an value type equivalent to the existing _SwiftNativeNSError class,
but in the opposite direction. This would remove the need for Swift code to deal with
NSErrors and would clean up quite a few pain points that currently exist with error handling.


Swift-evolution thread: [Consistent bridging for NSErrors at the language boundary](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160502/016618.html)

## Motivation

Over the past couple of years, Swift has made great strides toward
seamless interoperability with existing Objective-C APIs. With
SE-0005, SE-0033, SE-0057, SE-0062, SE-0064, and SE-0070, Swift seems poised
to become even better in that regard. However, there still exists one
major pain point when going back and forth between Swift and Objective-C,
and that lies in the area of error reporting. Passing errors between
Objective-C and Swift APIs is currently quite awkward, for several reasons:

- The Swift-approved mechanism for reporting errors is represented by
a protocol named ErrorType (ErrorProtocol in the latest sources).
However, Objective-C Cocoa APIs represent errors using a class named
NSError. In addition to being a reference type, which feels quite
unnatural for an error object by Swift’s conventions, NSError follows
a paradigm to store error information which is foreign to Swift, employing
a string-based domain and and integer code, along with a userInfo dictionary
to store information to be presented to the user. While the domain and code
are available as methods on ErrorProtocol, they are prefixed with underscores,
and there is no direct equivalent to userInfo.

- Unlike other fundamental Objective-C classes like NSString and NSArray, which are
consistently bridged to value types when presenting Objective-C interfaces
to Swift, the handling of NSError objects is inconsistent. Objective-C APIs
which return an error by reference using an autoreleasing NSError ** pointer
are converted so that they use the Swift try/catch mechanism, and present the returned
error as an ErrorProtocol (which is actually an NSError). Similarly, Swift
APIs using try/catch are presented to Objective-C as returning NSErrors by 
reference, and when an ErrorProtocol-conforming error is thrown by such an API,
it is converted to an NSError when called by Objective-C (which happens often when
following many Cocoa design patterns, notably when implementing a document-based
application and implementing NSDocument's -readFromData:ofType:error: and similar
methods). However, when passing around error objects via any means other than try/catch
on the Swift side or returning an error object by reference on the Objective-C side,
the errors are not bridged. An Objective-C API that takes an NSError, such as NSApp’s
-presentError: method, still leaves NSError as the type in the interface presented to
Swift, as do the many asynchronous APIs in Cocoa that return an NSError as one of the arguments
to a completion handler. Swift APIs that accept ErrorProtocols, on the other
hand, are not presented to Objective-C at all, necessitating any such APIs
also be declared to accept NSErrors instead for the sake of interoperability.

- To convert ErrorProtocols to NSErrors, Swift provides a bridging mechanism,
invoked via “as NSError”, which wraps the error in a private NSError subclass
named _SwiftNativeNSError. This subclass can be cast back to the original
error type, thus returning the original wrapped error. When a Swift API that
is marked “throws” is called from Objective-C and then throws an error, the
same bridging mechanism is invoked. However, this bridging is not very useful,
since Cocoa tends to use NSError’s userInfo dictionary to present error information
to the user, and ErrorProtocol contains no equivalent to the userInfo dictionary.
The result of this is that when a Swift API throws an error, and this error is
passed to Cocoa, the user tends to get a generic error message instead of
something actually useful.

- The above problem means that a Swift developer must be very careful never
to use “as NSError”, and to be sure to construct an NSError when throwing an
error in an API that may be called from Objective-C, rather than simply throwing
the error directly, or else the error will not be properly presented. If the
developer makes a mistake here, it will not be known until runtime. I have
personally wasted quite a bit of time trying to hunt down points in a complicated
program where an error was accidentally converted to NSError via the bridge
rather than explicitly.

- The same problem also puts the Swift developer between a rock and a hard place,
if they have other code that wants to check these errors. In a pure-Swift program,
checking against a particular error can often be done simply via a conditional
cast to the ErrorProtocol-conforming type that we are interested in.
If the error has been converted to NSError via the bridge, this method works, since
the bridge will return the original Swift error when casted. However, if the API
that threw the error has been conscientious about constructing an NSError to avoid
the userInfo issue, the NSError will not be easily castable back to the original
Swift error type. Instead, the developer will have to compare the NSError’s error
domain and code. The code itself will have to have been assigned by the throwing
API. As the domain is stringly-typed and the code will often be extraneous to the
actual error definition, this is all very runtime-dependent and can easily become 
incorrect or out of sync, which will break the program’s error reporting.

- The UI for creating NSError objects is extremely verbose and un-Swift-like,
usually requiring two lines of code: one to construct a dictionary, with an extremely
verbose key—NSLocalizedFailureReasonErrorKey—to indicate the actual error message text
to the user, and one to construct the NSError object. The latter is itself quite verbose,
requiring the developer to enter values for a domain and code which she typically does
not care about, since ErrorProtocol provides decent enough default implementations for
those values in most cases.

- Due to bugs in the bridging mechanism, it is possible for a _SwiftNativeNSError to get
run a second time through the bridge, which removes the userInfo dictionary altogether,
once again result in incorrect error reporting.

- The need for the “as NSError” bridging mechanism makes it more difficult to implement
otherwise positive changes such as Joe Groff’s proposal to simplify the “as?” keyword
(https://github.com/apple/swift-evolution/pull/289).

- Finally, the fact that Swift code that deals with errors must always be filled with
either “as NSError” statements or explicit NSError initializations sprinkled through
results in code that is quite a bit uglier than it needs to be.

## Proposed solution

I propose consistently bridging NSError to a value type whenever it is exposed to
Swift code via an API signature, and doing the equivalent in the opposite direction,
similarly to how NSStrings and Strings are bridged to and from each other in API signatures.

The benefits of this approach are many:

1. This is very similar to the bridging that already exists for String<->NSString,
Array<->NSArray, when crossing the language boundary, so this improves the consistency
of the language.

2. Special-case type checks would be mostly restricted to the special magic that the
compiler inserts when crossing the boundary, thus reducing the potential for bugs.

3. NSError is no longer required to conform to ErrorProtocol, reducing the type checking
that has to go on during the bridging process, also reducing the potential for bugs.

4. Since the is, as, as?, and as! operators would no longer be needed to bridge NSErrors
to native errors and back, improvements to that mechanism such as
(https://github.com/apple/swift-evolution/pull/289) become viable, and the casting operators
can be made to no longer act in ways that are often surprising and confusing.

5. The programmer never has to deal with NSError objects in Swift code again.

## Detailed design

1. Extend ErrorProtocol such that it has public, non-underscored methods for the
domain, code, and userInfo. The first two of these retain their existing default
implementations, whereas the last of these will have a default implementation that
just returns an empty dictionary. The user can override any of these to provide more
information as needed.

2. NSError’s conformance to ErrorProtocol is removed, since Swift code will generally
no longer need to work directly with NSErrors.

3. A new private error value type is introduced that conforms to ErrorProtocol. Since
this type will be private, its specific name is up to the implementers, but for the
purpose of this example we will assume that it is named _ObjCErrorType. This type wraps
an NSError, and forwards its domain, code, and userInfo properties to it.

4. The existing _SwiftNativeNSError class remains, and continues to work as it does
currently, although it is extended to forward the userInfo property to the wrapped
Swift error. Thus, this class now wraps a native Swift error and forwards the domain,
code, and userInfo properties to it.

5. Objective-C APIs that return an NSError object present it as ErrorProtocol in the
signature. When called by Swift, the type of the NSError is checked. If the type is
_SwiftNativeNSError, the original Swift error is unwrapped and returned. Otherwise,
the NSError is wrapped in an instance of _ObjCErrorType and returned as an ErrorProtocol.

6. Objective-C APIs that take NSError objects now show ErrorProtocol in their signatures
as well. If an _ObjCErrorType is passed to one of these APIs, its wrapped NSError is
unwrapped and passed to the API. Otherwise, the error is wrapped in a _SwiftNativeNSError
and passed through to the API.

7. Swift errors would still be convertible to NSError, if the developer needed to do so
manually. This could be done either via the current “as NSError” bridge, or via initializers
and/or accessors on NSError.

The bridging would work in all the places that NSString->String bridging works now, and would look like the following:

```
let stringGotThrough: NSString = …
let errorGotThrough: NSError = …
let userInfo: [NSObject : AnyObject] = …

let string = stringGotThrough as String
let error = errorGotThrough as ErrorProtocol

if let failureReason = userInfo[NSLocalizedFailureReasonErrorKey] as? String {
    print(“Failed because: \(failureReason)”)
}

if let underlyingError = userInfo[NSUnderlyingErrorKey] as? ErrorProtocol {
    // do something with the underlying error
}
```

The obvious caveat here is that since ErrorProtocol is a protocol rather than
a concrete type, the bridging magic we have in place probably isn’t able to
handle that, and would need to be extended. If I had to guess, I’d suppose
this is why this isn’t implemented already. However, if Joe’s bridging magic
reduction proposal (https://github.com/apple/swift-evolution/pull/289) and
Riley’s factory initializers proposal (https://github.com/apple/swift-evolution/pull/247),
both of which I think would be positive improvements to the language, are implemented,
then this actually gets a lot easier (and simpler) to implement, as it would all be done
through factory initializers, which thanks to Riley’s proposal, we’d be able to put
on a protocol. So in this case, we’d have:

```
let stringGotThrough: NSString = …
let errorGotThrough: NSError = …
let userInfo: [NSObject : AnyObject] = …

let string = String(stringGotThrough)
let error = ErrorProtocol(errorGotThrough)

if let failureReason = String(userInfo[NSLocalizedFailureReasonWhyIsThisNameSoDamnLongErrorKey]) {
    print(“Failed because: \(failureReason)”)
}

if let underlyingError = ErrorProtocol(userInfo[NSUnderlyingErrorKey]) {
    // do something with the error
}
```

The factory initializers (or bridging magic) would work like this:

`ErrorProtocol()` or “`as? ErrorProtocol`”: Checks if the object is a _SwiftNativeNSError, and if it is, unwraps the underlying native Swift error. Otherwise, it checks if we have an NSError, and if we do, it wraps it in an _ObjCErrorType. If it’s not an NSError at all, this returns nil.

`NSError()` or “`as? NSError`”: Checks if the object is an _ObjCErrorType, and if it is, unwraps the underlying NSError. Otherwise, it checks if we have an ErrorProtocol, and if we do, it wraps it in a _SwiftNativeNSError. If it’s not an ErrorProtocol at all, this returns nil.

## Impact on existing code

Required changes to existing code will be rather small, mostly involving removing “as NSError”
statements. In cases where developer have implemented workarounds to the problem solved by
this proposal, those workarounds can be removed from the code, as they will no longer be needed.

## Alternatives considered

### Leave the underscores on the methods for the domain, name, and code

This is viable; however, Swift is closely tied to Objective-C, and errors coming from Objective-C
will present themselves via NSError's domain, code, and userInfo properties. Therefore, interpreting
these errors requires easy access to these methods.

### Instead of _ObjCErrorType, make the bridging type a public and non-underscored value type simply named Error.

This would require the least amount of modification to the current bridging mechanism. However, it muddies the
waters conceptually between whether errors should be fundamentally understood as a concrete type or a protocol,
and could be confusing to novice users.

### Do nothing

This would leave the error handling mechanism in its current inconsistent and often confusing state.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
