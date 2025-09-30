# Warn When Member Access Level Exceeds Enclosing Type

* Proposal: [SE-NNNN](NNNN-warn-when-member-access-level-exceeds-enclosing-type.md)
* Authors: [Artem Kalinovsky](https://github.com/artemkalinovsky)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: Not yet implemented
* Review: ([pitch](https://forums.swift.org/t/warn-when-member-access-level-exceeds-enclosing-type/82446))

## Introduction

We propose introducing compiler warnings for redundant access control modifiers when a member's declared access level exceeds its enclosing type's effective access level. In Swift's access control model, a member cannot be more accessible than its enclosing type, making such declarations misleading and potentially confusing. This proposal aims to improve code clarity and help developers better understand the actual accessibility of their APIs.

## Motivation

Swift's access control system follows a fundamental rule: no entity can be more accessible than its enclosing context. For example, a `public` property of an `internal` struct is effectively `internal`, regardless of the explicit `public` modifier. However, the compiler currently accepts such declarations without any warnings, leading to several problems:

### 1. Misleading Code and False Expectations

Consider this example:

```swift
struct User: Decodable {
    struct Name: Decodable {
        let title: String
        let first: String
        let last: String
    }
    
    public let name: Name
    let email: String

    public func foo() {
        print("Hello World!")
    }
}
```

Here, the `User` struct has the default `internal` access level. The `public` modifiers on `name` and `foo()` suggest these members are publicly accessible, but they are effectively `internal`. This creates false expectations for developers reading or maintaining the code.

### 2. Code Review Confusion

When reviewing pull requests, team members might assume that marking a member as `public` makes it part of the public API. They may spend time discussing API design implications for members that aren't actually publicly accessible.

### 3. Maintenance Burden

As codebases evolve, developers might change an outer type's access level without realizing that inner members have redundant modifiers. This creates visual noise and makes it harder to understand the true access boundaries of a module.

### 4. Learning Curve for New Swift Developers

Newcomers to Swift might not understand why their `public` member isn't accessible from another module, leading to confusion about how access control works. A compiler diagnostic would provide immediate feedback and education about Swift's access control rules.

### 5. API Evolution Pitfalls

When developers later decide to make an internal type public, they might overlook members that already have `public` modifiers, assuming they're already correctly configured. This can lead to unintended API surface exposure.

Currently, developers must rely on manual code review, third-party linters, or trial-and-error to catch these issues. The compiler has all the information needed to detect these redundant modifiers but provides no feedback.

## Proposed solution

We propose adding compiler warnings when a member's explicitly declared access level exceeds its enclosing type's effective access level. The compiler will emit a clear diagnostic with fix-it suggestions to either remove the redundant modifier or adjust the enclosing type's access level.

Example warning:

```swift
internal struct User {
    public let name: Name  // Warning: 'public' modifier is redundant; 
                          // 'name' is effectively 'internal' because 
                          // its enclosing type 'User' is 'internal'
    
    public func foo() {}   // Warning: 'public' modifier is redundant; 
                          // 'foo()' is effectively 'internal' because 
                          // its enclosing type 'User' is 'internal'
}
```

The warnings help developers understand the actual access level of their declarations and encourage cleaner, more accurate code.

## Detailed design

### Diagnostic Rules

The compiler will emit a warning when all of the following conditions are met:

1. A member (property, method, subscript, initializer, or nested type) has an **explicit** access level modifier
2. The explicit access level is **more permissive** than the effective access level of its enclosing type
3. The enclosing type's effective access level limits the member's actual accessibility

Access levels in order from least to most permissive:
- `private`
- `fileprivate`
- `internal` (default)
- `public`
- `open` (classes and class members only)

### Examples of Warnings

```swift
// Warning: 'public' is redundant
internal struct Config {
    public var apiKey: String
}

// Warning: 'public' is redundant
fileprivate class Logger {
    public func log(_ message: String) {}
}

// Warning: 'internal' is redundant  
fileprivate struct Settings {
    internal var timeout: Int
}

// Warning: 'public' is redundant (limited by outermost type)
internal class Outer {
    public class Middle {
        public func bar() {}
    }
}
```

### No Warning Cases

```swift
// No warning: 'public' matches the struct's access level
public struct Config {
    public var apiKey: String
}

// No warning: 'internal' is less permissive than 'public'
public struct User {
    internal var privateData: String
}

// No warning: no explicit modifier
internal struct Data {
    var value: Int  // implicitly internal
}

// No warning: 'private' and 'fileprivate' are intentionally restrictive
public struct Account {
    private var balance: Double
    fileprivate var id: UUID
}
```

### Fix-It Suggestions

The compiler should provide two fix-it options:

1. **Remove the redundant modifier** (primary suggestion):
   ```
   Fix-It: Remove 'public' modifier
   ```

2. **Make the enclosing type match** (alternative suggestion):
   ```
   Fix-It: Change 'internal struct User' to 'public struct User'
   ```

### Nested Types

The diagnostic correctly handles deeply nested types by comparing against the most restrictive enclosing scope:

```swift
internal class A {
    public class B {        // Warning: redundant 'public' (limited by A)
        public class C {    // Warning: redundant 'public' (limited by A)
            public func m() // Warning: redundant 'public' (limited by A)
        }
    }
}
```

### Extensions

Extensions inherit the access level of the type they extend (or can specify their own):

```swift
internal struct User {}

extension User {
    public func foo() {}  // Warning: redundant 'public'
}

public extension User {   // Warning: extension cannot be more accessible
    func bar() {}         // effectively internal
}
```

## Source compatibility

This proposal is purely additive and introduces only warnings. It does not change the behavior of any existing valid Swift code. All code that currently compiles will continue to compile with the same semantics, but some code may now produce warnings.

Developers can:
1. Fix the warnings by removing redundant modifiers
2. Fix the warnings by adjusting enclosing type access levels
3. Suppress warnings in legacy code if needed (using compiler flags)

This is a progressive enhancement to the developer experience and does not break source compatibility.

## ABI compatibility

This proposal has no ABI impact. It only affects compile-time diagnostics and does not change how code is generated, what symbols are exported, or how declarations interact at the binary level. The actual access level of declarations remains unchanged from current behavior.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

Developers can immediately benefit from these warnings in any Swift version that implements this proposal. There are no runtime or library version requirements, as this is purely a compile-time diagnostic feature.

For library maintainers, cleaning up redundant access modifiers is a non-breaking change that improves code clarity without affecting API or ABI stability.

## Future directions

### Making This an Error

In a future Swift version (e.g., Swift 7 or beyond), we could consider promoting this warning to a compile-time error. This would make Swift's access control even more explicit and prevent misleading code from being written. This transition would follow Swift's typical evolution process with appropriate migration tools.

### Extended Access Control Analysis

This proposal could be extended to detect other access control anti-patterns:

- Warning when an `open` class has only `final` methods (making `open` ineffective)
- Suggesting `final` on classes that are never subclassed within their module
- Detecting when `public` types expose non-public types in their API signatures (which already causes errors, but better diagnostics could help)

### Tooling Integration

The compiler diagnostics could be integrated with:
- Swift-DocC to validate that documentation matches actual accessibility
- Swift Package Manager to analyze public API surface area
- IDE quick-fixes and refactoring tools for bulk cleanup

### Cross-Module Analysis

A more advanced version could warn about patterns across module boundaries, such as when internal types are only used within a small subset of files and could be more restrictive.

## Alternatives considered

### Do Nothing (Status Quo)

We could continue relying on developer awareness, code reviews, and third-party linters. However, this misses an opportunity for the compiler to provide immediate, contextual feedback about a common source of confusion. The compiler already has all the information needed to detect these issues.

### Make This an Error Immediately

We could make redundant access modifiers a compile-time error rather than a warning. While this would be maximally effective at preventing misleading code, it would also break a significant amount of existing code that, while redundant, is still technically valid. A warning provides a gentler migration path and allows teams to address these issues on their own schedule.

### Only Warn for `public` and `open`

We could limit warnings to only `public` and `open` modifiers, since these are the most likely to cause confusion about external API surface. However, `internal` modifiers can also be misleading in `fileprivate` contexts, and developers benefit from understanding access control at all levels.

### Provide Only Fix-Its Without Warnings

Some might suggest that warnings are too noisy and the compiler should just silently offer fix-its. However, warnings serve an important educational purpose, helping developers understand Swift's access control model and why their code doesn't work as expected.

### Make It Opt-In via Compiler Flag

Rather than enabling this by default, we could require developers to opt in with a compiler flag like `-warn-redundant-access-control`. This would reduce noise for teams that don't want these warnings, but it would also mean most developers never benefit from the feature. Given that this addresses a real source of confusion and the fix is straightforward, making it default behavior is more valuable.

### Integrate into Swift Format or SwiftLint

This could be implemented as a linting rule rather than a compiler warning. However, compiler diagnostics provide more immediate and universal feedback. Not all projects use linters, but everyone uses the compiler. Additionally, the compiler has the most accurate view of access control semantics, making it the ideal place for this check.

## Acknowledgments

Thanks to the Swift community members who have raised concerns about misleading access control modifiers over the years, and to those who have implemented similar checks in third-party linters, demonstrating the value of this feedback.
