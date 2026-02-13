# Discardable result use in Task initializers

* Proposal: [SE-NNN](NNN-discardableresult-task-initializers.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: https://github.com/swiftlang/swift/pull/87171
* Review: TBD

## Summary of changes

Previously, `@discardableResult` was applied universally to all Task initializers, making it too easy to accidentally miss that a thrown error was ignored. We propose to only apply discardable result treatment to non-throwing Task initializers.

## Motivation

Currently the following code, in which a function inside an unstructured task is throwing an error results in no warnings being emitted:

```swift
Task { // no warning
  try boom() 
}
print("Yay!")
```

In simple snippets like this it may be obvious that we missed to handle the error, however real codebases often have more noise and it is possible to miss the fact that we silently ignored the error.

This issue has been raised multiple times in the Swift community, however none wound up resulting in a complete proposal to actually make the change:

- [Task initializer with throwing closure swallows error](https://forums.swift.org/t/task-initializer-with-throwing-closure-swallows-error/56066)
- [Pitch: non-discardable throwing tasks](https://forums.swift.org/t/pitch-non-discardable-throwing-tasks/74138)
- [Pitch: Improved error handling in unstructured task initializers](https://forums.swift.org/t/pitch-improved-error-handling-in-unstructured-task-initializers/74826)

The origin of this semantic is that originally this `Task {}` syntax was primarily intended for fire-and-forget semantics, and we did not account enough for the possibility of accounting for the thrown errors. This behavior however is inconsistent with Swift's error handling model and leads to hard-to-find bugs where errors are silently swallowed.

## Detailed design

The concurrency library has now adopted typed throws in `Task.init`, `Task.detached`, `Task.immediate`, `Task.immediateDetached`, so the only change needed for this proposal is to remove the `@discardableResult` annotation:

```swift
extension Task {
  @discardableResult // REMOVE
  public init(...)
}

extension Task where Failure == Never {
  @discardableResult // keep
  public init(...)
}
```

Which will result in the following warning behaviors:

```swift
Task {  }
Task { throws in ... } // warning: result of call to 'init(name:priority:operation:)' is unused
Task { throws(Boom) in ... } // warning: result of call to 'init(name:priority:operation:)' is unused

Task.detached {  }
Task.detached { throws in ... } // warning: result of call to 'detached(name:priority:operation:)' is unused
Task.detached { throws(Boom) in ... } // warning: result of call to 'detached(name:priority:operation:)' is unused

// etc.
```

And it is possible to silence the issue by explicitly ignoring the value:

```swift
_ = Task { throws in ... }
```

The same change will be applied to all other unstructured task initializers.

## Source compatibility

The change is source compatible, however may cause new warnings to be emitted.

Those warnings can be silenced by explicitly discarding the task value: `_ = Task { try boom() }`

## ABI compatibility

This proposal does not affect ABI as it only changes compile-time diagnostic behavior.

## Alternatives considered

### Do nothing

We feel the community has voiced this as a problem for long enough, and we should improve the situation here.

### Also remove discardableResult from non-throwing initializers

We believe that non-throwing values which return either Void or non-Void values are usually intentionally fire and forget -- otherwise you would be interested in using the resulting value, and be forced to store the task (or await it immediately). Therefore we do not propose to remove this attribute from Task initializers which _do not_ throw.

## Acknowledgments

Everyone in the previous pitch threads, thank you for raising the issue.
