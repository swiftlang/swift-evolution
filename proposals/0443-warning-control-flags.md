
# Precise Control Flags over Compiler Warnings

* Proposal: [SE-0443](0443-warning-control-flags.md)
* Authors: [Doug Gregor](https://github.com/douggregor), [Dmitrii Galimzianov](https://github.com/DmT021)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 6.1)**
* Implementation: [apple/swift#74466](https://github.com/swiftlang/swift/pull/74466)
* Review: ([pitch](https://forums.swift.org/t/warnings-as-errors-exceptions/72925)) ([review](https://forums.swift.org/t/se-0443-precise-control-flags-over-compiler-warnings/74116)) ([acceptance](https://forums.swift.org/t/accepted-se-0443-precise-control-flags-over-compiler-warnings/74377))
* Previous revisions: [1](https://github.com/swiftlang/swift-evolution/blob/57fe29d5d55edb85b14c153b7f4cbead6b6539eb/proposals/0443-warning-control-flags.md), [2](https://github.com/swiftlang/swift-evolution/blob/7b12899ad0d96002c793d33ef8109ec47c5d256f/proposals/0443-warning-control-flags.md)

## Introduction

This proposal introduces new compiler options that allow fine-grained control over how the compiler emits certain warnings: as warnings or as errors.

## Motivation

The current compiler options for controlling how warnings are emitted are very inflexible. Currently, the following options exist:
- `-warnings-as-errors` - upgrades all warnings to errors
- `-no-warnings-as-errors` - cancels the upgrade of warnings to errors
- `-suppress-warnings` - disables the emission of all warnings

This lack of flexibility leads to situations where users who want to use `-warnings-as-errors` find themselves unable to do so, or unable to upgrade to a new version of the compiler or SDK until all newly diagnosed warnings are resolved. The most striking example of this is deprecation warnings for certain APIs, though they are not limited to them.

## Proposed solution

This proposal suggests adding new options that will allow the behavior of warnings to be controlled based on their diagnostic group.
- `-Werror <group>` - upgrades warnings in the specified group to errors
- `-Wwarning <group>` - indicates that warnings in the specified group should remain warnings, even if they were previously suppressed or upgraded to errors

The `<group>` parameter is a string identifier of the diagnostic group.

A diagnostic group is a stable identifier for an error or warning. It is an abstraction layer over the diagnostic identifiers used within the compiler. This is necessary because diagnostics within the compiler may change, but we need to provide stable user-facing identifiers for them.

A diagnostic group may include errors, warnings, or other diagnostic groups. For example, the `DeprecatedDeclaration` diagnostic group includes warnings related to the use of an API marked with the `@available(..., deprecated: ...)` attribute. The `Deprecated` diagnostic group includes the `DeprecatedDeclaration` group and other groups related to deprecation.

Diagnostic groups may expand over time, but they can never become narrower. When a new diagnostic is added to the compiler, it is either included in an existing group or a new group is created for it, which in turn can also be included in one of the broader groups, if appropriate.

The order in which these flags are specified when invoking the compiler is important. If two or more options change the behavior of the same warning, we follow the rule "the last one wins."

We also retain the existing compiler options but modify their handling algorithm so that they are considered in the general list with the new options and follow the "last one wins" rule as well.

Thus, for example, you can use the combination `-warnings-as-errors -Wwarning Deprecated`, which will upgrade all warnings to errors except for those in the `Deprecated` group. However, if these flags are specified in the reverse order(`-Wwarning Deprecated -warnings-as-errors`) it will be interpreted as upgrading all warnings to errors, as the `-warnings-as-errors` flag is the last one.

We are also introducing a new compiler flag, `-print-diagnostic-groups`, to display the names of diagnostic groups along with the textual representation of the warnings. When used, the warning message will be followed by the name of the narrowest group that includes that warning, enclosed in square brackets. For example:
```
main.swift:33:1: warning: 'f()' is deprecated [#DeprecatedDeclaration]
```

## Detailed design

### Diagnostic groups

Diagnostic groups form an acyclic graph with the following properties:

- A warning or error can only be included in one diagnostic group. This artificial restriction is introduced to solve two main problems:
  - When using the `-print-diagnostic-groups` flag, it would be inconvenient if a warning corresponded to multiple groups.
  - Documentation lookup will also be easier for the user if a diagnostic has only one identifier.

- A diagnostic group may include any number of other diagnostic groups. This will allow organizing groups into sets with similar meanings but different specific diagnostics. For example, the warnings `DeprecatedDeclaration` and `UnsafeGlobalActorDeprecated` are part of the supergroup `Deprecated`.

- A diagnostic group can be included in any number of diagnostic groups. This allows expressing the membership of a group in multiple supergroups, where appropriate. For example, the group `UnsafeGlobalActorDeprecated` is part of both the `Deprecated` and `Concurrency` groups.

The internal structure of the graph may change to some extent. However, the set of diagnostics included in a diagnostic group (directly or transitively) should not shrink. There are two typical situations where the graph structure may change:
- When adding a new diagnostic to the compiler, consider creating a new group corresponding to that diagnostic. If the new group is created it can also be included in one or more existing groups if it belongs to them. For example, it is expected that the `Deprecated` group will continuously include new subgroups.
- If an existing diagnostic is split into more specific versions, and we want to allow users to use the more specific version in compiler options, a separate group is created for it, which **must** be included in the group of the original diagnostic.

  For example, suppose we split the `DeprecatedDeclaration` warning into a general version and a specialized version `DeprecatedDeclarationSameModule`, which the compiler emits if the deprecated symbol is declared in the same module. In this case, the `DeprecatedDeclarationSameModule` group must be added to the `DeprecatedDeclaration` group to ensure that the overall composition of the `DeprecatedDeclaration` group does not change. The final structure should look like this:
  ```
  DeprecatedDeclaration (group)
  ├─ DeprecatedDeclaration (internal diag id)
  └─ DeprecatedDeclarationSameModule (group)
     └─ DeprecatedDeclarationSameModule (internal diag id)
  ```
  Thus, invoking the compiler with the `-Werror DeprecatedDeclaration` parameter will cover both versions of the warning, and the behavior will remain unchanged. At the same time, the user can control the behavior of the narrower `DeprecatedDeclarationSameModule` group if they want to.

### Compiler options evaluation

Each warning in the compiler is assigned one of three behaviors: `warning`, `error`, or `suppressed`.
Compiler options for controlling the behavior of groups are now processed as a single list. These options include:
```
-Werror <group>
-Wwarning <group>
-warnings-as-errors
-no-warnings-as-errors
```
When these options are passed to the compiler, we sequentially apply the specified behavior to all warnings within the specified group from left to right. For `-warnings-as-errors` and `-no-warnings-as-errors`, we apply the behavior to all warnings.

Examples of option combinations:
- `-warnings-as-errors -Wwarning Deprecated`
  
  Warnings from the `Deprecated` group will be kept as warnings, but all the rest will be upgraded to errors.

- `-Werror Deprecated -Wwarning DeprecatedDeclaration` 
  
  Warnings from the `DeprecatedDeclaration` group will remain as warnings. Other warnings from the `Deprecated` group will be upgraded to errors. All others will be kept as warnings.

It’s crucial to understand that the order in which these flags are applied can significantly affect the behavior of diagnostics. The rule is "the last one wins", meaning that if multiple flags apply to the same diagnostic group, the last one specified on the command line will determine the final behavior.

It is also important to note that the order matters even if the specified groups are not explicitly related but have a common subgroup.
For example, as mentioned above, the `UnsafeGlobalActorDeprecated` group is part of both the `Deprecated` and `Concurrency` groups. So the order in which options for the `Deprecated` and `Concurrency` groups are applied will change the final behavior of the `UnsafeGlobalActorDeprecated` group. Specifically:

- `-Wwarning Deprecated -Werror Concurrency` will make it an error,
- `-Werror Concurrency -Wwarning Deprecated` will keep it as a warning.

#### Interaction with `-suppress-warnings`

This proposal deliberately excludes `-suppress-warnings` and its group-based counterpart from the new unified model. We retain the behavior of the existing `-suppress-warnings` flag but forbid its usage with the new options. The following rules will be applied:

- It is forbidden to combine `-suppress-warnings` with `-Wwarning` or `-Werror`. The compiler will produce an error if these options are present in the command line together.
- It is allowed to be combined with `-no-warnings-as-errors`. The current compiler behavior permits the usage of `-no-warnings-as-errors` or `-warnings-as-errors -no-warnings-as-errors` with `-suppress-warnings`. We will maintain this behavior.
- It remains position-independent. Whenever `-no-warnings-as-errors` and `-suppress-warnings` are combined, `-suppress-warnings` will always take precedence over `-no-warnings-as-errors`, regardless of the order in which they are specified.

### Usage of `-print-diagnostic-groups` and `-debug-diagnostic-names`

As mentioned earlier, we are adding support for the `-print-diagnostic-groups` compiler option, which outputs the group name in square brackets.

A similar behavior already exists in the compiler and is enabled by the `-debug-diagnostic-names` option, but it prints the internal diagnostic identifiers used in the compiler. For example:
```swift
@available(iOS, deprecated: 10.0, renamed: "newFunction")
func oldFunction() { ... }

oldFunction()
```
When compiled with the `-debug-diagnostic-names` option, the following message will be displayed:
```
'oldFunction()' is deprecated: renamed to 'newFunction' [#RenamedDeprecatedDeclaration]
```
The string `RenamedDeprecatedDeclaration` is the internal identifier of this warning, not the group. Accordingly, it is not supported by the new compiler options.

When compiling the same code with the `-print-diagnostic-groups` option, the following message will be displayed:
```
'oldFunction()' is deprecated: renamed to 'newFunction' [#DeprecatedDeclaration]
```
Here, the string `DeprecatedDeclaration` is the diagnostic group.

Often, group names and internal diagnostic identifiers coincide, but this is not always the case.

We retain support for `-debug-diagnostic-names` in its current form. However, to avoid confusion between diagnostic IDs and diagnostic groups, we prohibit the simultaneous use of these two options.

## Source compatibility

This proposal has no effect on source compatibility.

## ABI compatibility

This proposal has no effect on ABI compatibility.

## Implications on adoption

The adoption of diagnostic groups and the new compiler options will provide a foundation for flexible and precise control over warning behavior. However, to make this useful to end-users, significant work will be needed to mark existing diagnostics in diagnostic groups. It will also be necessary to develop a process for maintaining the relevance of diagnostic groups when new diagnostics are introduced in the compiler.

## Future directions

### Support in the language

While diagnostic groups are introduced to support the compiler options, it may be possible in the future to standardize the structure of the group graph itself. This could open up the possibility of using these same identifiers in the language, implementing something analogous to `#pragma diagnostic` or `[[attribute]]` in C++. It could also address suppressing warnings entirely, which isn't covered by this proposal. However, such standardization and the design of new language constructs go far beyond the scope of this proposal, and we need to gain more experience with diagnostic groups before proceeding with this.

### Support in SwiftPM

If this proposal is accepted, it would make sense to support these parameters in SwiftPM as well, allowing the behavior of warnings to be conveniently specified in SwiftSetting.

## Alternatives considered

### Alternatives to diagnostic groups
#### Status quo
The lack of control over the behavior of specific diagnostics forces users to abandon the `-warnings-as-errors` compiler option and create ad-hoc compiler wrappers that filter its output.

#### Using existing diagnostic identifiers
Warnings and errors in Swift can change as the compiler evolves.
For example, one error might be renamed or split into two that are applied in different situations to improve the clarity of the text message depending on the context. Such a change would result in a new ID for the new error variant.

The example of `DeprecatedDeclarationSameModule` illustrates this well. If we used the warning ID, the behavior of the compiler with the `-Wwarning DeprecatedDeclaration` option would change when a new version of the warning is introduced, as this warning would no longer be triggered for the specific case of the same module.

Therefore, we need a solution that allows us to modify errors and warnings within the compiler while providing a reliable mechanism for identifying diagnostics that can be used by the user.

#### Flat list instead of a graph

To solve this problem, we could use an additional alias-ID for diagnostics that does not change when the main identifier changes.

Suppose we split the `DeprecatedDeclaration` diagnostic into a generic variant and `DeprecatedDeclarationSameModule`. To retain the existing name for the new variant, we could describe these two groups as
```
DeprecatedDeclaration (alias: DeprecatedDeclaration)
DeprecatedDeclarationSameModule (alias: DeprecatedDeclaration)
```
However, this solution would not allow specifying the narrower `DeprecatedDeclarationSameModule` or the broader group `Deprecated`.

#### Using multiple alias IDs for diagnostics
To express a diagnostic's membership in multiple groups, we could allow multiple alias-IDs to be listed.
```
DeprecatedDeclaration aliases:
  DeprecatedDeclaration
  Deprecated
DeprecatedDeclarationSameModule aliases:
  DeprecatedDeclarationSameModule
  DeprecatedDeclaration
  Deprecated
```
However, such a declaration lacks structure and makes it difficult to understand which alias-ID is the most specific.

### Alternative names for the compiler options

During the design process, other names for the compiler options were considered, which were formed as the singular form of the existing ones:
| Plural                   | Singular                       |
|--------------------------|--------------------------------|
| `-warnings-as-errors`    | `-warning-as-error <group>`    |
| `-no-warnings-as-errors` | `-no-warning-as-error <group>` |

In Clang, diagnostic behavior is controlled through `-W...` options, but the format suffers from inconsistency. We adopt the `-W` prefix while making the format consistent.
| Clang             | Swift                |
|-------------------|----------------------|
| `-W<group>`       | `-Wwarning <group>`  |
| `-Wno-<group>`    |                      |
| `-Werror=<group>` | `-Werror <group>`    |

The option name `-Wwarning` is much better suited when it comes to enabling suppressed-by-default warnings. Today we have several of them behind dedicated flags like `-driver-warn-unused-options` and `-warn-concurrency`. It might be worth having a common infrastructure for warnings that are suppressed by default.

### Alternative format for `-print-diagnostic-groups`

Theoretically, we could allow the simultaneous use of `-debug-diagnostic-names` and `-print-diagnostic-groups`, but this would require choosing a different format for printing diagnostic groups.

Since `-debug-diagnostic-names` has been available in the compiler for a long time, we proceed from the fact that there are people who rely on this option and its format with square brackets.

To avoid overlap, we would need to use a different format, for example:
```
'foo()' is deprecated [#DeprecatedDeclaration] [group:#DeprecatedDeclaration]
```

However, even this does not eliminate the possibility of breaking code that parses the compiler's output.

Moreover, `-print-diagnostic-groups` provides a formalized version of the same functionality using identifiers suitable for user use. And thus it should supersede the usages of `-debug-diagnostic-names`. Therefore, we believe the best solution would be to use the same format for `-print-diagnostic-groups` and prohibit the simultaneous use of these two options.

## Revision History

- Revisions based on review feedback:
  - `-Wsuppress` was excluded from the proposal. 
  - `-suppress-warnings` was excluded from the unified model and addressed separately by forbidding its usage with the new flags.
  - The guideline in the "Diagnostic Groups" subsection for adding a new diagnostic has been softened to a consideration.

## Acknowledgments

Thank you to [Frederick Kellison-Linn](https://forums.swift.org/u/Jumhyn) for the idea of addressing the `-suppress-warnings` behavior without incorporating it into the new model.
