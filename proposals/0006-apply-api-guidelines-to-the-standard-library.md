# Apply API Guidelines to the Standard Library

* Proposal: [SE-0006](https://github.com/apple/swift-evolution/blob/master/proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* Author(s): [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Status: **Awaiting Review**
* Review manager: [Doug Gregor](https://github.com/DougGregor)

## Introduction

[Swift API Design Guidelines][api-design-guidelines] being developed as
part of Swift 3.  It is important that the Standard Library is an exemplar of
Swift API Design Guidelines: the APIs from the Standard Library are, probably,
the most frequently used Swift APIs in any application domain; the Standard
Library also sets precedent for other libraries.

In this project, we are reviewing the entire Standard Library and updating it
to follow the guidelines.

## Proposed solution

The actual work is being performed on the [swift-3-api-guidelines
branch][swift-3-api-guidelines-branch] of the [Swift repository][swift-repo].
On high level, the changes can be summarized as follows.

* Strip `Type` suffix from remaining protocol names.  In a few special cases
  this means adding a `Protocol` suffix to get out of the way of type
  names that are primary (though most of these we expect to be
  obsoleted by Swift 3 language features).

* The concept of `generator` is renamed to `iterator`.

* `IndexingGenerator` is renamed to `DefaultCollectionIterator`.

**More changes will be summarized here as they are implemented.**

## API diffs

Differences between Swift 2.2 Standard library API and the proposed API are
added to this section as they are being implemented on the
[swift-3-api-guidelines branch][swift-3-api-guidelines-repo].

## Impact on existing code

The proposed changes are massively source-breaking for Swift code, and will
require a migrator to translate Swift 2 code into Swift 3 code.  The API diffs
from this proposal will be the primary source of the information about the
required transformations.  In addition, to the extent the language allows, the
library will keep old names as unavailable symbols with a `renamed` annotation,
that allows the compiler to produce good error messages and emit Fix-Its.

[api-design-guidelines]: https://swift.org/documentation/api-design-guidelines.html  "API Design Guidelines"
[swift-repo]: https://github.com/apple/swift  "Swift repository"
[swift-3-api-guidelines-branch]: https://github.com/apple/swift/tree/swift-3-api-guidelines  "Swift 3 API Design Guidelines preview"

