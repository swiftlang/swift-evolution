# Swift Programming Language Evolution
[![Swift](https://img.shields.io/badge/Swift%204%20stage%202-Open%20to%20requests-brightgreen.svg)](#swift_stage)


**Before you initiate a pull request**, please read the process document. Ideas should be thoroughly discussed on the [swift-evolution mailing list](https://swift.org/community/#swift-evolution) first.

This repository tracks the ongoing evolution of Swift. It contains:

* Goals for upcoming Swift releases (this document).
* The [Swift evolution review status][proposal-status] tracking proposals to change Swift.
* The [Swift evolution process](process.md) that governs the evolution of Swift.
* [Commonly Rejected Changes](commonly_proposed.md), proposals which have been denied in the past.

This document describes goals for the Swift language on a per-release
basis, usually listing minor releases adding to the currently shipping
version and one major release out.  Each release will have many
smaller features or changes independent of these larger goals, and not
all goals are reached for each release.

Goals for past versions are included at the bottom of the document for
historical purposes, but are not necessarily indicative of the
features shipped. The release notes for each shipped version are the
definitive list of notable changes in each release.
<a name="swift_stage"></a>
## Development major version:  Swift 4.0

Expected release date: Late 2017

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

## Previous releases

* [Swift 3.0](releases/swift-3_0.md) - Released on September 13, 2016
* [Swift 2.2](releases/swift-2_2.md) - Released on March 21, 2016

[proposal-status]: https://apple.github.io/swift-evolution/




Apache License
                           Version 2.0, January 2004
                        https://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2019 Rolando Gopez Lacuata

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       https://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
