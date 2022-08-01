# Conditional compilation for attributes

* Proposal: [SE-0367](0367-conditional-attributes.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (August 1...August 15, 2022)**

* Implementation: [apple/swift#60208](https://github.com/apple/swift/pull/60208)
* Swift-evolution thread: [Pitch](https://forums.swift.org/t/pitch-conditional-compilation-for-attributes-and-modifiers/58339)

## Introduction

Over time, Swift has introduced a number of new attributes to communicate additional information in source code. Existing code can then be updated to take advantage of these new constructs to improve its behavior, providing more expressive capabilities, better compile-time checking, better performance, and so on.

However, adopting a new attribute in existing source code means that source code won't compile with an older compiler. Conditional compilation can be used to address this problem, but the result is verbose and unsatisfactory. For example, one could use `#if` to check the compiler version to determine whether to use the `@preconcurrency` attribute:

```swift
#if compiler(>=5.6)
@preconcurrency protocol P: Sendable {
  func f()
  func g()
}
#else
protocol P: Sendable {
  func f()
  func g()
}
#endif
```

This is unsatisfactory for at least two reasons. First, it's a lot of code duplication, because the entire protocol `P` needs to be duplicated just to provide the attribute. Second, the Swift 5.6 compiler is the first to contain the `@preconcurrency` attribute, but that is somewhat incidental and not self-documenting: the attribute could have been enabled by a compiler flag or partway through the development of Swift 5.6, making that check incorrect. Moreover, the availability of some attributes can depend not on compiler version, but on platform and configuration flags: for example, `@objc` is only available when the Swift runtime has been compiled for interoperability with Objective-C. Although these are small issues in isolation, they make adopting new attributes in existing code harder than it needs to be.

## Proposed solution

I propose two related changes to make it easier to adopt new attributes in existing code:

* Allow `#if` checks to surround attributes on a declaration wherever they appear, eliminating the need to clone a declaration just  to adopt a new attribute.
* Add a conditional directive `hasAttribute(AttributeName)` that evalutes `true` when the compiler has support for the attribute with the name `AttributeName` in the current language mode.

The first two of these can be combined to make the initial example less repetitive and more descriptive:

```swift
#if hasAttribute(preconcurrency)
@preconcurrency
#endif
protocol P: Sendable {
  func f()
  func g()
}
```

## Detailed design

The design of these features is relatively straightforward, but there are a few details to cover.

### Grammar changes

The current production for an attribute list:

```
attributes → attribute attributes[opt]
```

will be augmented with an additional production for a conditional attribute:

```
attributes → conditional-compilation-attributes attributes[opt]

conditional-compilation-attributes → if-directive-attributes elseif-directive-attributes[opt] else-directive-attributes[opt] endif-directive
if-directive-attributes → if-directive compilation-condition attributes[opt]
elseif-directive-attributes → elseif-directive-attributes elseif-directive-attributes[opt]
elseif-directive-attributes → elseif-directive compilation-condition attributes[opt]
else-directive-attributes → else-directive attributes[opt]
```

i.e., within an attribute list one can have a conditional clause `#if...#endif` that wraps another attribute list.

### `hasAttribute` only considers attributes that are part of the language 

A number of Swift language features, including property wrappers, result builders, and global actors, all introduce forms of custom attributes. For example, a type `MyWrapper` that has been marked with the `@propertyWrapper` attribute (and meets the other requirements for a property wrapper type) can be used with the attribute syntax `@MyWrapper`. While the built-in attribute that enables the feature will be recognized by `hasAttribute` (e.g., `hasAttribute(propertyWrapper)` will evaluate `true`), the custom attribute will not (e.g., `hasAttribute(MyWrapper)` will evaluate `false`).

### Parsing the conditionally-compiled branches not taken

Due to support for custom attributes, attributes have a very general grammar that should suffice for any new attributes we introduce into Swift:

```
attribute → @ attribute-name attribute-argument-clause[opt]
attribute-name → identifier
attribute-argument-clause → ( balanced-tokens[opt] )
```

Therefore, a conditionally-compiled branch based on `#if hasAttribute(UnknownAttributeName)` can still be parsed by an existing compiler, even though it will not be applied to the declaration because it isn't understood:

```swift
#if hasAttribute(UnknownAttributeName)
@UnknownAttributeName(something we do not understand) // okay, we parse this but don't reject it
#endif
func f()
```

