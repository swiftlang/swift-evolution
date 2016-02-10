# Overridable Members in Extensions

* Proposal: SE-NNNN
* Author: [Jordan Rose](https://github.com/jrose-apple)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Today, methods introduced in an extension of a class cannot override or be
overridden unless the method is (implicitly or explicitly) marked `@objc`. This
proposal lifts the blanket restriction while still enforcing safety.

> Note: it's already plan-of-record that if the extension is in the same module
> as the class, the methods will be treated as if they were declared in the
> class itself. This proposal only applies to extensions declared in a
> different module.

<!--swift-evolution thread: [link to the discussion thread for that
proposal](https://lists.swift.org/pipermail/swift-evolution)-->


## Motivation

This is used to add operations to system or library classes that you can
customize in your own classes, as seen in the Apple [AdaptivePhotos][] sample
code.

    extension UIViewController {
      func containsPhoto(photo: Photo) -> Bool {
        return false
      }
    }

<!-- file boundary -->

    class ConversationViewController : UIViewController {
      // …
      override func containsPhoto(photo: Photo) -> Bool {
        return self.conversation.photos.contains(photo)
      }
    }

[AdaptivePhotos]: https://developer.apple.com/library/ios/samplecode/AdaptivePhotos/Listings/AdaptiveCode_AdaptiveCode_UIViewController_PhotoContents_swift.html

Additional motivation: parity with Objective-C. If Objective-C didn't allow
this, we might not have done it, but right now the answer is "if your method is
ObjC-compatible, just slap an attribute on it; otherwise you're out of luck",
which isn't really a sound design choice.


### Today's Workaround

If you know every class that needs a custom implementation of a method, you can
use dynamic casts to get the same effect:

    extension UIViewController {
      final func containsPhoto(photo: Photo) -> Bool {
        switch self {
        case is ListTableViewController:
          return true
        case let cvc as ConversationViewController:
          return cvc.conversation.photos.contains(photo)
        default:
          return false
        }
      }
    }

But this is not possible if there may be subclasses outside of the module, and
it either forces all of the implementations into a single method body or
requires adding dummy methods to each class.


## Proposed solution

This proposal lifts the restriction on non-`@objc` extension methods (and
properties, and subscripts) by requiring an alternate dispatch mechanism that
can be arbitrarily extended. To preserve safety and correctness, a new,
narrower restriction will be put in place:

**If an extension in module `B` is extending a class in module `A`, it may only
override members added in module `B`.**

Any other rule can result in two modules trying to add an override for the same
method on the same class.

> Note: This rule applies to `@objc` members as well as non-`@objc` members.

There is no restriction on extensions adding new *overridable* members. These
members can be overridden by any extension in the same module (by the above
rule) and by a subclass in any module, whether in the class declaration itself
or in an extension in the same module.


## Detailed design

Besides safety, the other reason we didn't add this feature is because the
Swift method dispatch mechanism uses a single virtual dispatch table for a
class, which cannot be arbitrarily extended after the fact. The implementation
would require an alternate dispatch mechanism that *can* be arbitrarily
extended.

On Apple platforms this is implemented by the Objective-C method table; we
would provide a simplified implementation of the same on Linux. For a selector
we would use the mangled name of the original overridden method. These methods
would still use Swift calling conventions; they're just being stored in the
same lookup table as Objective-C methods.


### Library Evolution

As with [any other method][], it is legal to "move" an extension method up to
an extension on the base class, as long as the original declaration is not
removed entirely. The new entry point will forward over to the original entry
point in order to preserve binary compatibility.

[any other method]:
https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst#classes


## Impact on existing code

No existing semantics will be affected. Dispatch for methods in extensions may
get slower, since it's no longer using a direct call.


## Alternatives considered

### All extension methods are `final`

This is sound, and doesn't rule out the "closed class hierarchy" partial
workaround described above. However, it does prevent some reasonable patterns
that were possible in Objective-C, and it is something we've seen developers
try to do (with or without `@objc`).

### `@objc` extension methods are overridable, non-`@objc` methods are not

This is a practical answer, since it requires no further implementation work.
We could require members in extensions to be explicitly annotated `dynamic` and
`final`, respectively, so that the semantics are at least clear. However, it's
not a very principled design choice: either overridable extension members are
useful, or they aren't.


## Future extensions

The restriction that an extension cannot override a method from another module
is intended for safety purposes, preventing two modules from each adding their
own override. It's possible to make this a link-time failure rather than a
compile-time failure by emitting a dummy symbol representing the (class,
member) pair. Because of this, it may be useful to have an "I know what I'm
doing" annotation that promises that no one else will add the same member; if
it does happen then the program will fail to link.

(Indeed, we probably should do this anyway for `@objc` overrides, which run the
risk of run-time collision because of Objective-C language semantics.)

If we ever have an "SPI" feature that allows public API to be restricted to
certain clients, it would be reasonable to consider relaxing the safety
restrictions for those clients specifically on the grounds that the library
author trusts them to know what they're doing.
