# Discardable result use in Task initializers

* Proposal: [SE-0520](0520-discardableresult-task-initializers.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Accepted**
* Implementation: [PR #87439](https://github.com/swiftlang/swift/pull/87439/)
* Review: ([pitch](https://forums.swift.org/t/pitch-remove-discardableresult-from-throwing-task-initializers/84721)) ([review](https://forums.swift.org/t/se-0520-discardable-result-use-in-task-initializers/85374)) ([acceptance](https://forums.swift.org/t/accepted-se-0520-discardable-result-use-in-task-initializers/86159))

## Summary of changes

Previously, `@discardableResult` was applied universally to all Task initializers, making it too easy to accidentally miss that a thrown error was ignored. We propose to introduce a new warning that will be applied to throwing Task initializers, in order to help developers not "miss" handling errors thrown by tasks.

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

The concurrency library has now adopted typed throws in `Task.init`, `Task.detached`, `Task.immediate`, `Task.immediateDetached`, we build on top of this by introducing a new warning kind which recognizes the thrown type (`throws(Failure)`) and only triggers if the failure type is not-`Never`.

Previous iterations of this proposal used multiple overloads and removed the `@discardableResult` from the specific method when the where the `Failure` type was `Never`. This would result in duplicating declarations again, even though we adopted typed throws in order to lessen the number of necessary overloads. 

Instead, this proposal will introduce a new bespoke warning mechanism which is able to trigger

Which will result in the following warning behaviors:

```swift
Task {  }
// no warning

Task { throws in ... } 
// warning: Unstructured throwing task was not used, which may accidentally ignore errors thrown inside the task [#NoUseUnstructuredThrowingTask]
// note: To silence this warning, handle the error inside the task, or store/discard the task value explicitly

Task { throws(Boom) in ... } 
// warning: Unstructured throwing task was not used, which may accidentally ignore errors thrown inside the task [#NoUseUnstructuredThrowingTask]
// note: To silence this warning, handle the error inside the task, or store/discard the task value explicitly

Task { throws(Never) in ... }
// no warning
```

And similarily for all other unstructured task creation (immediate tasks etc).

We also provide additional documentation about this in a new warning group which further explains the problem.

It is possible to silence the issue by explicitly ignoring the value:

```swift
_ = Task { throws in ... }
```

Or just by actually using the value, which is the way how you'd observe thr thrown error:

```swift
let task = Task { throws in } 

let value = try await task.value // would throw the error if task failed 
```

The same change will be applied to all unstructured task initializers.

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
