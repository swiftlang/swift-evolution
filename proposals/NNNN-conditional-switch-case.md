# Allow `#if` to guard switch case clauses

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Rintaro Ishizaki](https://github.com/rintaro)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal adds ability to guard switch `case` clauses with `#if` directives.

Swift-evolution thread: [Allow `#if` to guard switch case clauses](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170508/036568.html)

## Motivation

When you want to switch cases only for certain compilation condition, say switching `#if os(Linux)` guarded enum cases, right now you have to write `switch` twice:

```swift
enum Operation {
  case output(String)
#if os(Linux)
  case syscall(Syscall)
#endif
}

func execute(operation: Operation) {
#if !os(Linux)
   switch operation {
     case .output(let str):
        print(str)
   }
#else
   switch operation {
     case output(let str):
        print(str)
     case .syscall(let call):
        call.execute()
   }
#endif
}
```

This is annoying and error prone.

## Proposed solution

This proposal allows `#if` to guard switch case clauses.

```swift
func execute(operation: Operation) {
    switch operation {
    case .output(let str):
        print(str)
#if os(Linux)
    case .syscall(let call):
        call.execute()
#endif
    }
}
```

## Detailed design

This change shouldn't affect existing `#if` directives *within* `case` clauses. This code should work as expected:

```swift
func foo(x: MyEnum) {
    switch x {
    case .some(let str):
        doSomething(str)
#if PRINT_SOME
        print(str)
#endif
    case .other:
        doOther()
    }
}
```

Only if the next token after `#if` line is `case` or `default`, the Parser treat it as guarding `case` clauses.

```swift
func foo(x: MyEnum) {
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHER
    case .other:
        doOther()
#endif
    }
}
```
```swift
func foo(x: MyEnum) {
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHER
    default:
        break
#endif
    }
}
```

Error cases:

```swift
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHER
    case .other:
        doOther()
#else
        doMore() // error: all statements inside a switch must be covered by a 'case' or 'default'
#endif
    }
```

```swift
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHER
        doMore()
    case .other:
        doOther() // error: 'case' label can only appear inside a 'switch' statement
#endif
    }
```
```swift
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHER
    case .other:
        doOther()
#endif
        doMore() // error: all statements inside a switch must be covered by a 'case' or 'default'
    }
```

You can guard multiple cases as long as it is guarding whole `case`s:

```swift
    switch x {
    case .some(let str):
        doSomething(str)
#if HAS_OTHERS
    case .other:
        doOther()
    case .more:
        doMore()
#endif
    }
```

## Source compatibility

As this is purely additive proposal, it does not affect existing code

## Effect on ABI stability

This change does not affect ABI.

## Alternatives considered

N/A
