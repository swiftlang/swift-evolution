# Relaxed floating-point operators

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors:[](https://github.com/swiftdev) [Steve Canon](https://github.com/stephentyrone)
* Review Manager: TBD
* Status: ****Awaiting review**\*\*
* Implementation: [swiftlang/swift#92991](https://github.com/swiftlang/swift/pull/92991)
* Review:

## Summary of changes
Define operators on floating-point types that permit the compiler to apply "normal" algebraic transformations that make it easier for users to explicitly trade-off bitwise reproducibility for improved performance.

## Motivation
Consider the following function:
```
func foo(a: Float, b: Float, c: Float, d: Float) -> Float {
  a*b + c + d
}
```
Evaluating the result expression requires three operations: a multiply and two adds, and all three are serially dependent. If we assume that a floating-point add and multiply both take n cycles¹, the latency of the expression as a whole will be 3n cycles.

If we, the programmer, transform the function as follows:
```
func foo2(a: Float, b: Float, c: Float, d: Float) -> Float {
  a*b + (c + d)
}
```
then it still requires three operations, but they are no longer serially dependent. The multiply and the parenthesized add can be evaluated simultaneously, so the latency of evaluating the expression as a whole is now only 2n cycles--that's a 33% improvement.

If we happen to be targeting a CPU with a fused multiply-add instruction, we could rewrite the function as:
```
func foo3(a: Float, b: Float, c: Float, d: Float) -> Float {
  (c + d).addingProduct(a, b)
}
```
Now its latency is still 2n cycles, but we only require two instructions instead of three, which--depending on the balance of other instructions in the program--may also be a significant improvement.

Isn't an optimizing compiler supposed to make these decisions for us? Especially for generating `foo3`, where we have to make decisions about the targeted architecture that would require us to write multiple codepaths?

The compiler would be happy to make these transforms, but we have to give it license to do so, because the transformations discussed above will slightly perturb the result; floating-point operations are not generally associative. Not only would introducing these transformations cause the sequence of roundings (and therefore the final result) to be different from what the programmer wrote, it would sometimes result in different roundings on different machines (because forming a fused multiply-add is only advantageous if there is hardware support).

Sometimes, getting exactly reproducible results is of chief concern. Certainly it is the easiest default to explain and to debug, and so we do not want to change the behavior of `+` or `*`. But sometimes, the specific rounding and bitwise reproducibility are _not_ concerns, and in those cases, it makes sense to provide users with a means to tell the compiler so, so that it can give them the fastest code it can.

---
¹ floating-point add and multiply don't necessarily have the same cost, but on mainstream architectures they are at least within a small factor of eachother, so this is close enough to illustrate our goals.

## Proposed solution

Introduce six new operators on `FloatingPoint`: `&+`, `&-`, `&*`, `&+=`, `&-=`, `&*=` that have _relaxed_ semantics, permitting reassociation and FMA formation.

Programmers are then able to use these new operators to opt-in to relaxed floating-point arithmetic on a case-by-case basis, without any file-level or module-level flag or state. Copying expressions from one file into another preservers their meaning, so behavior does not subtly change in ways that might be hard to predict.

The performance benefits of doing this can be quite large, because reassociation in particular tends to unlock vectorization where it would otherwise not be possible. Consider computing a dot product:
```
func dot(_ a: Span<Float>, _ b: Span<Float>) -> Float {
  precondition(a.count == b.count)
  return a.indices.reduce(into: 0) { accum, index in
    accum += a[index] * b[index]
  }
}
```
This generates the following main loop:
```
loop:
    ldp     q1, q2, [x9,  #-0x20]
    ldp     q3, q4, [x9], #0x40
    ldp     q5, q6, [x10, #-0x20]
    ldp     q7,q16, [x10],#0x40
    fmul.4s v1,      v1,  v5
    mov     s5,      v1[3]
    mov     s17,     v1[2]
    mov     s18,     v1[1]
    fmul.4s v2,      v2,  v6
    mov     s6,      v2[3]
    mov     s19,     v2[2]
    mov     s20,     v2[1]
    fmul.4s v3,      v3,  v7
    mov     s7,      v3[3]
    mov     s21,     v3[2]
    mov     s22,     v3[1]
    fmul.4s v4,      v4,  v16
    mov     s16,     v4[3]
    mov     s23,     v4[2]
    mov     s24,     v4[1]
    fadd    s0,      s0,  s1
    fadd    s0,      s0,  s18
    fadd    s0,      s0,  s17
    fadd    s0,      s0,  s5
    fadd    s0,      s0,  s2
    fadd    s0,      s0,  s20
    fadd    s0,      s0,  s19
    fadd    s0,      s0,  s6
    fadd    s0,      s0,  s3
    fadd    s0,      s0,  s22
    fadd    s0,      s0,  s21
    fadd    s0,      s0,  s7
    fadd    s0,      s0,  s4
    fadd    s0,      s0,  s24
    fadd    s0,      s0,  s23
    fadd    s0,      s0,  s16
    subs    x11,     x11, #0x10
    b.ne    loop
```

This is not great. It has a total serial dependency on the accumulator, so it will run at a speed of at most one element per add latency.

If we make no changes other than adopting the new operators:
```
func dot(_ a: Span<Float>, _ b: Span<Float>) -> Float {
  precondition(a.count == b.count)
  return a.indices.reduce(into: 0) { accum, index in
    accum &+= a[index] &* b[index]
  }
}
```
then we get the following:
```
    ldp     q4,  q5,  [x10, #-0x20]
    ldp     q6,  q7,  [x10],#0x40
    ldp     q16, q17, [x11, #-0x20]
    ldp     q18, q19, [x11],#0x40
    fmla.4s v0,        v4,  v16
    fmla.4s v1,        v5,  v17
    fmla.4s v2,        v6,  v18
    fmla.4s v3,        v7,  v19
    subs    x12,       x12, #0x10
    b.ne    loop
```
You don't need to know a lot of assembly to understand that this is better for most use, but I'll call out some highlights: it is completely vectorized, it uses fused multiply-add instead of separate multiply and add operations, and it maintains four separate accumulators to break up the dependency chain. This loop can run at a rate of sixteen elements per add latency.

You may note that the loop is also quite a bit smaller! This is _sometimes_, but not always, a win for codesize, becuase it saves us from partially-vectorized loops with large scalar sections as we saw above.

Somewhat counterintuitively, the relaxed dot product is actually _more accurate_ on average (in that for most real-world input distributions, the average rounding error of the result computed this way will be smaller than than the average rounding error of the result computed with strict FP operations). The precise analysis of why this happens is a little bit subtle, but a handwavy sketch is easy to state: because reassociation licenses the compiler to use multiple accumulators instead of a single accumulator, the maximum magnitude of the value in each accumulator tends to stay smaller. Because rounding errors in an addition are proportional to the magnitude of the arguments, this means that most of the rounding errors are smaller, and so the total error is smaller.

So it's faster, smaller code size, and produces a more accurate result! Why don't we just make the normal `*` and `+` operator behave this way? Because it will generate different results on different targets, resulting in hard to diagnose bugs in some cases. For instance, if I compile the above loop for apple-macos26-x86_64, I get:
```
loop:
    movups   (%rdi,%rcx,4), %xmm2
    movups 16(%rdi,%rcx,4), %xmm3
    movups   (%rdx,%rcx,4), %xmm4
    mulps     %xmm2,        %xmm4
    addps     %xmm4,        %xmm1
    movups 16(%rdx,%rcx,4), %xmm2
    mulps     %xmm3,        %xmm2
    addps     %xmm2,        %xmm0
    addq      $8,           %rcx
    cmpq      %rcx,         %rax
    jne       loop
```
This is _similar_ but not the same as what we got for arm64. It uses two SIMD4 accumulators instead of four, processing eight elements per iteration, and uses separate multiply and add instructions instead of FMA. Still more accurate (on average) than the strict algorithm, but a totally different sequence of roundings than the relaxed algorithm produced on arm64.

If I enable FMA instructions for x86 (`-target apple-macos26-x86_64 -Xcc -mfma`), we get code that does four SIMD8 accumulators (32 elements per cycle), giving still another sequence of roundings. So even within an architecture, the precise rounding behavior will vary depending on options (and sometimes depending on compiler versions).

For these reasons, we definitely would not want these operators to be the default. Nonetheless, they are extremely useful, and it would be a shame not to have them at all.

## Detailed design

We introduce six new protocol requirements for types conforming to `FloatingPoint`: the operators `&+`, `&-`, `&*`, `&+=`, `&-=`, and `&*=`. These operators have default implementations that simply delegate to the usual "strict" floating-point operators.

For each of the concrete floating-point types in the standard library, we provide an implementation that uses the newly-introduced `f[op]_relaxed` builtins, which expand to `fadd`, `fsub`, or `fmul` LLVM IR nodes with the "reassociate", "contract" and "no signed zeros" flags set. These license the compiler to reassociate expressions and form fused multiply-adds fairly generally.

## Source compatibility

Minimal effect on source compatibility.

## ABI compatibility


This is a purely additive feature.

## Implications on adoption

 The concrete operators are unconditionally available. The protocol customization points will have availability. Thus, you can use the relaxed operations on concrete types regardless of deployment target, but generic code written against FloatingPoint will only benefit from them when targeting a newer platform version on binary-stable targets. It is, of course, possible to work around this by introducing your own protocol and conforming the concrete floating-point types to it.

## Future directions

It may be desirable to extend "relaxed" floating-point semantics to some other operations in the future. `min` and `max` are good examples, where the precise edge case semantics of arm and x86 instructions mean that source language expressions with strict semantics cannot bind the raw instructions on one or both targets. A relaxed `min` and `max` that opt-in to "I don't care what happens to NaN" would make it possible for these operations to unconditionally have a single-instruction expansion.

But add, subtract, and multiply are by far the three most valueable cases. They allow users to write fairly natural code without a lot of detailed analysis and get acceptable results for a wide range of algorithms.

## Alternatives considered

The non-obvious part of this proposal is the spelling; everything else is fairly well-trod ground blazed by other languages. Instead of `&+`, `&-` and `&*`, we could have adopted a file- or module-scoped setting for this, or we could have defined alternative operators with the usual spelling in a different module that would shadow the strict operators when imported. I feel that all of these alternatives are undesirable because they leave you with no way to look at an expression and know what the operators mean with only local information (this is technically already the case, because modules can shadow operators, but to do it deliberately within the toolchain would be a major step for the worse).

Alternatively, we could give these names like what I prototyped them as in Numerics years ago: `Relaxed.sum` and `Relaxed.product`. These avoid ambiguity, but they are quite unwieldy. They make for nice examples, but wholesale adapting a large block of code makes it much less readable.

The `&`-prefixed operators strike a reasonable compromise. They are different enough to call out that something weird is going on, but concise enough to keep code readable, and already familiar from integer arithmetic. The parallel to the integer `&` operators is imperfect--these do not wrap. But it's not so bad, either: the integer `&` operators make integer add and multiply associative and permit vectorization, where it otherwise would not be due to overflow traps. These operators make the compiler pretend that floating-point add and multiply are associative and permit vectorization, where it otherwise would not be due to rounding.

## Acknowledgments

Thanks to Ben Cohen for prodding me to do something about this.
