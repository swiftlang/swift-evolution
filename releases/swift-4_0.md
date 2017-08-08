# Swift 4.0 - Expected to be released in Late 2017

**Swift 4 is currently in engineering convergence, and no more evolution proposals are being accepted for this release.**

The Swift 4 release is designed around two primary goals: to provide
source stability for Swift 3 code and to provide ABI stability for the
Swift standard library. To that end, the Swift 4 release will be
divided into two stages.

Stage 1 focused on the essentials required for source and ABI
stability. Features that don't fundamentally change the ABI of
existing language features or imply an ABI-breaking change to the
standard library will not be considered in this stage. 

Stage 2 opened in mid-February and extends until April 1, 2017, after
which proposals will be held for a later version of Swift.

The high-priority features supporting Stage 1's source and ABI
stability goals are:

* Source stability features: the Swift language will need [some
  accommodations](https://github.com/apple/swift-evolution/blob/master/proposals/0141-available-by-swift-version.md)
  to support code bases that target different language versions, to
  help Swift deliver on its source-compatibility goals while still
  enabling rapid progress.

* Resilience: resilience provides a way for public APIs to evolve over
  time, while maintaining a stable ABI. For example, resilience
  eliminates the [fragile base class
  problem](https://en.wikipedia.org/wiki/Fragile_base_class) that
  occurs in some object-oriented languages (e.g., C++) by describing
  the types of API changes that can be made without breaking ABI
  (e.g., "a new stored property or method can be added to a class").

* Stabilizing the ABI: There are a ton of small details that need to
  be audited and improved in the code generation model, including
  interaction with the Swift runtime. While not specifically
  user-facing, the decisions here affect performance and (in some rare
  cases) the future evolution of Swift.

* Generics improvements needed by the standard library: the standard
  library has a number of workarounds for language deficiencies, many
  of which manifest as extraneous underscored protocols and
  workarounds. If the underlying language deficiencies remain, they
  become a permanent part of the stable ABI. [Conditional
  conformances](https://github.com/apple/swift-evolution/blob/master/proposals/0143-conditional-conformances.md),
  [recursive protocol
  requirements](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#recursive-protocol-constraints-),
  and [where clauses for associated
  types](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md)
  are known to be in this category, but it's plausible that other
  features will be in scope if they would be used in the standard
  library.

* String re-evaluation: String is one of the most important
  fundamental types in the language. Swift 4 seeks to make strings more
  powerful and easier-to-use, while retaining Unicode correctness by
  default.

* Memory ownership model: an (opt-in) Cyclone/Rust-inspired memory
  ownership model is highly desired by systems programmers and for
  other high-performance applications that want predictable and
  deterministic performance. This feature will fundamentally shape the
  ABI, from low-level language concerns such as "inout" and low-level
  "addressors" to its impact on the standard library. While a full
  memory ownership model is likely too large for Swift 4 stage 1, we
  need a comprehensive design to understand how it will change the
  ABI.

Swift 4 stage 2 builds on the goals of stage 1. It differs in that
stage 2 proposals may include some additive changes and changes to
existing features that don't affect the ABI. There are a few focus
areas for Swift 4 stage 2:

* Stage 1 proposals: Any proposal that would have been eligible for
  stage 1 is a priority for stage 2.

* Source-breaking changes: The Swift 4 compiler will provide a
  source-compatibility mode to allow existing Swift 3 sources to
  compile, but source-breaking changes can manifest in "Swift 4"
  mode. That said, changes to fundamental parts of Swift's syntax or
  standard library APIs that breaks source code are better
  front-loaded into Swift 4 than delayed until later
  releases. Relative to Swift 3, the bar for such changes is
  significantly higher:

  * The existing syntax/API being changed must be actively harmful.
  * The new syntax/API must clearly be better and not conflict with existing Swift syntax.
  * There must be a reasonably automatable migration path for existing code.

* Improvements to existing Standard Library facilities: Additive
  changes that improve existing standard library facilities can be
  considered. With standard library additions in particular, proposals
  that provide corresponding implementations are preferred. Potential
  focus areas for improvement include collections (e.g., new
  collection algorithms) and improvements to the ergonomics of
  `Dictionary`.

* Foundation improvements: We anticipate proposing some targeted
  improvements to Foundation API to continue the goal of making the
  Cocoa SDK work seamlessly in Swift. Details on the specific goals
  will be provided as we get started on Swift 4 stage 2.
