
* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-tail-call-optimization.md)
* Author(s): [griotspeak](https://github.com/griotspeak)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Tail call optimization can be a powerful tool when implementing certain types of algorithms. Unfortunately, Tail call optimization cannot be consistently used in Swift code. Developers cannot be sure that opportunities for this particular optimization to be applied are, in fact, being realized. This discrepancy can cause dramatic differences from expected and actual performance. An attribute, similar to Scala's `tailrec`, along with LLVM warnings, could allow a clear indicator of when such optimizations are not guaranteed to work.

Swift-evolution thread: https://lists.swift.org/pipermail/swift-evolution/2015-December/000359.html

## Motivation

LLVM will perform tail call optimization when possible but cannot currently guarantee when applied. This is partially explained by Joe Groff in swift-evolution
> "… there are other low-level resources that need to be managed in the case of an arbitrary tail call, such as space on the callstack and memory for indirectly-passed parameters. Being able to manage these would require a special machine-level calling convention that would have overhead we don't want to spend pervasively to make arbitrary functions tail-callable."

 Swift developers currently have no insight into when TCO can or will occur.

``` swift
func fact(input: Int) -> Int {
    func _fact(n: Int, value: Int) -> (n: Int, value:Int) {
        if n <= 0 {
            return (0, value)
        } else {
            return _fact(n - 1, value: n * value)
        }
    }

    return _fact(input, value: 1).value
}
```
In the provided example, the developer can be reasonably sure that tail call optimization is possible but, without either a universal guarantee or something like the proposed attribute, there is no way to be sure that such an optimization will occur.

## Proposed solution

Adding an attribute would provide developers with concrete knowledge of when TCO can and will be performed by LLVM in compiling their swift code. 

``` swift
func fact(input: Int) -> Int {
	@tailrec
    func _fact(n: Int, value: Int) -> (n: Int, value:Int) {
    ...
}

// Call site where TCO is expected
tail return fact(3)
```
With this attribute and return modifier combination, the developer can express the desire for TCO and warnings can be emitted if TCO cannot be guaranteed. If there are currently only a few such cases, developers are made aware of what those cases are and can design implementations with this information at hand. As LLVM's ability to provide TCO increases, the allowed cases simply grow with no effect for the initial narrow cases.
We should, at first, work to support the simplest cases and only allow self-recursive tail calls, which avoid some of the aforementioned stack and memory management problems that can be encountered in arbitrary tail call. 
If the user attempts to use `@tailrec` and `defer` together, the compiler should emit and error , as deferred blocks occur after the return expression is evaluated. We should also provide feedback to the developer so that they understand that the defer is blocking TCO.

## Detailed design
In the minimal case, implementation of this feature can consist solely of the attribute and output from LLVM indicating whether or not the requested optimization can be guaranteed. To quote Joe Groff once more, guaranteed support for self recursive tail calls 'can likely be implemented mostly in SILGen by jumping to the entry block, without any supporting backend work. Arbitrary tail calls can be supported in the fullness of time.'.

## Impact on existing code

This should not have any breaking impact as it is strictly additive and diagnostic.

## Future Enhancements ##

This proposal is meant to clarify when tail call optimization will be applied and lay the foundation for expansion of supported cases.  Possible cases which we could support in the future are

- allowing tail calls between functions in the same module, so that the compiler has enough information to use the tail-callable convention only where needed,
- allowing tail calls between functions in the same module or external functions marked with a '@tail_callable' attribute.

## Alternatives considered ##

- We could add the keyword without expanding the supported cases in any way. 
- We could allow deferred blocks to be executed before the expression in a `tail return` if there is a motivating reason. 
	- Slava Pestov pointed out that this could prove troublesome for code similar to

	``` swift
		func f() -> String {
			let fd = open(...)
			defer { close(fd) }
			return read(fd)
		}
```

	- Mark Lacey suggests that 
> "this could also be handled by passing continuations that should be run on the return paths of callees. The continuation a function passes to its callee would wrap the continuation passed to it by its caller, so they would get executed in the original order. That’s an ABI change though, and a potentially expensive one.
>
We’ve considered doing something like this as an optimization to enable more proper tail calls in other cases (e.g. for the ARC case where you release after return). This would be done by cloning callees, and adding a new parameter. It’s not clear how worthwhile it would be to pursue this, and how expensive it would be in terms of code bloat."

		Though, according to Joe Groff, 
> "For ARC stuff it seems to me we can ensure all parameters are callee-consumed @owned or @in, and move any non-argument cleanups before the tail call, which eliminates the need for any continuation to be passed."

		This may not be desirable as it would change the semantics of the function where the original goal of this proposal is to let the developer assert that TCO is desired and allow the compiler to emit an error when it cannot guarantee TCO. 

