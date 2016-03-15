# Decoupling Floating Point Strides from Generic Implementations

* Proposal: SE-0050
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: Withdrawn by Submitter
* Review manager: TBD

Swift strides create progressions along "notionally continuous one-dimensional values" using
a series of offset values. This proposal replaces the Swift's generic stride implementation 
with seperate algorithms for integer strides (the current implementation) and floating point strides.

This proposal was discussed on-list in the ["\[Discussion\] stride behavior and a little bit of a call-back to digital numbers"](http://article.gmane.org/gmane.comp.lang.swift.evolution/8014) thread.

## Motivation

`Strideable` is genericized across both integer and floating point types. A single implementation causes
floating point strides to accumulate errors through repeatedly adding `by` intervals. Floating point types 
deserve their own floating point-aware implementation that minimizes errors.

## Current Art
A `Strideable to` sequence returns the sequence of values (`self`, `self + stride`, `self + stride + stride`, ... *last*) where *last* is the last value in the progression that is less than `end`.

A `Strideable through` sequence currently returns the sequence of values (`self`, `self + stride`, `self + tride + stride`, ... *last*) where *last* is the last value in the progression less than or equal to `end`. There is no guarantee that `end` is an element of the sequence.

While floating point calls present an extremely common use-case, they use integer-style math that accumulates 
errors during execution. Consider this example:

```swift
let ideal = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
print(zip(Array(1.0.stride(through: 2.01, by: 0.1)), ideal).map(-))
// prints [0.0, 0.0, 2.2204460492503131e-16, 2.2204460492503131e-16, 
// 4.4408920985006262e-16, 4.4408920985006262e-16, 4.4408920985006262e-16, 
// 6.6613381477509392e-16, 6.6613381477509392e-16, 8.8817841970012523e-16, 
// 8.8817841970012523e-16]
```

* To create an array containing values from 1.0 to 2.0, the developer must add
  an epsilon value to the `through` argument. Otherwise the stride progression ends 
  near 1.9. Increasing the argument from `2.0` to `2.01` is sufficient to include 
  the end value.
* The errors in the sequence increase over time. You see this as 
  errors become larger towards the end of the progress. This is an artifact of
  the generic implementation.

## Detail Design

Under the current implementation, each floating point addition in a generic stride accrues errors. 
The following progression never reaches 2.0.

```
print(Array(1.0.stride(through: 2.0, by: 0.1)))
// Prints [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]
```

This same issue occurs with traditional C-style for loops. This is an artifact of floating 
point math, and not the specific Swift statements:

```
var array: [Double] = []
for var i = 1.0; i <= 2.0; i += 0.1 {
    array.append(i)
}
print("Array", array) 
// Prints Array [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]
```

Errors should not accumulate along highly sampled progressions. Ideally, you should not have to manually add an epsilon to force a progression to complete
if the math is fairly close to being right.

Floating point strides are inherently dissimilar to and should not be genericized with 
integer strides. I propose separate their implementation, freeing them to provide their 
own specialized progressions, using better numeric methods. In doing so, floating point 
values are no longer tied to implementations that unnecessarily accrue errors or otherwise 
provide less-than-ideal solutions.

The following example provides a rough pass at what a basic revamp might look like 
for floating point math. In actual deployment, this function would be named `stride` and not `fstride`.

```swift
import Darwin

/// A `GeneratorType` for `DoubleStrideThrough`.
public struct DoubleStrideThroughGenerator : GeneratorType {
    let start: Double
    let end: Double
    let stride: Double
    var iteration: Int = 0
    var done: Bool = false
    
    public init(start: Double, end: Double, stride: Double) {
        (self.start, self.end, self.stride) = (start, end, stride)
    }
    
    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Double? {
        if done {
            return nil
        }
        let current = start + Double(iteration) * stride; iteration += 1
        if signbit(current - end) == signbit(stride) { // thanks Joe Groff
            if abs(current) > abs(end) {
                done = true
                return current
            }
            return nil
        }
        return current
    }
}

public struct DoubleStrideThrough : SequenceType {
    let start: Double
    let end: Double
    let stride: Double
    
    /// Return a *generator* over the elements of this *sequence*.
    ///
    /// - Complexity: O(1).
    public func generate() -> DoubleStrideThroughGenerator {
        return DoubleStrideThroughGenerator(
            start: start, end: end, stride: stride)
    }
    
    init(start: Double, end: Double, stride: Double) {
        _precondition(stride != 0, "stride size must not be zero")
        (self.start, self.end, self.stride) = (start, end, stride)
    }
    
}

public extension Double {
    public func fstride(
        through end: Double, by stride: Double
        ) -> DoubleStrideThrough {
        return DoubleStrideThrough(
            start: self, end: end, stride: stride)
    }
}
```

This implementation reduces floating point error by limiting accumulated additions. It uses the
current Swift 2.2 `through` semantics (versus the revised `through` semantics proposed under
separate cover), so it never reaches 2.0 without adding an epsilon value.

```swift
print(Array(1.0.fstride(through: 2.0, by: 0.1)))
// prints [1.0, 1.1000000000000001, 1.2, 1.3, 1.3999999999999999,
//         1.5, 1.6000000000000001, 1.7000000000000002, 1.8, 
//         1.8999999999999999]

// versus the old style
print(Array(1.0.stride(through: 2.0, by: 0.1)))
// prints [1.0, 1.1000000000000001, 1.2000000000000002, 1.3000000000000003, 
//         1.4000000000000004, 1.5000000000000004, 1.6000000000000005, 
//         1.7000000000000006, 1.8000000000000007, 1.9000000000000008]

print(zip(Array(1.0.stride(through: 2.0, by: 0.1)), 
          Array(1.0.fstride(through: 2.0, by: 0.1))).map(-))
// prints [0.0, 0.0, 2.2204460492503131e-16, 2.2204460492503131e-16, 
//         4.4408920985006262e-16, 4.4408920985006262e-16, 4.4408920985006262e-16, 
//         4.4408920985006262e-16, 6.6613381477509392e-16, 8.8817841970012523e-16]

let ideal = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]
print(zip(Array(1.0.fstride(through: 2.0, by: 0.1)), ideal).map(-))
print(zip(Array(1.0.stride(through: 2.0, by: 0.1)), ideal).map(-))

// prints
// [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.2204460492503131e-16, 0.0, 0.0]
// [0.0, 0.0, 2.2204460492503131e-16, 2.2204460492503131e-16, 
//  4.4408920985006262e-16, 4.4408920985006262e-16, 4.4408920985006262e-16, 
//  6.6613381477509392e-16, 6.6613381477509392e-16, 8.8817841970012523e-16]
```

If one were looking for a quick and dirty fix, the same kind of math used in this
rough solution (`let value = start + count * interval`) could be adopted back into 
the current generic implementation.

## Alternatives Considered

You get far better results by converting floating point values to integer math, 
as in the following function. This works by calculating a precision multiplier derived 
from the whole and fractional parts of the start value, end value, and stride value, 
to determine a multiplier that enables fully integer math without losing precision.
This algorithm introduces significant overhead both for initialization and at each step,
making it a non-ideal candidate for real-world implementation beyond trivial stride progressions.
What floating point numbers really want here are a fast, well-implemented decimal type.


#### Integer Math

```swift
/// A `GeneratorType` for `DoubleStrideThrough`.
public struct DoubleStrideThroughGenerator : GeneratorType {
    let start: Int
    let end: Int
    let stride: Int
    let multiplier: Int
    var iteration: Int = 0
    var done: Bool = false
    
    public init(start: Double, end: Double, stride: Double) {
        
        // Calculate the number of places needed
        // Account for zero whole or fractions
        let wholes = [abs(start), abs(end), abs(stride)].map(floor)
        let fracs = zip([start, end, stride], wholes).map(-)
        
        let wholeplaces = wholes
            .filter({$0 > 0}) // drop all zeros
            .map({log10($0)}) // count places
            .map(ceil) // round up
        
        let fracplaces = fracs
            .filter({$0 > 0.0}) // drop all zeroes
            .map({log10($0)}) // count places
            .map(abs) // flip negative log for fractions
            .map(ceil) // round up
        
        // Extend precision by 10^2
        let places = 2.0
            + (wholeplaces.maxElement() ?? 0.0)
            + (fracplaces.maxElement() ?? 0.0)
        
        // Compute floating point multiplier
        let fpMultiplier = pow(10.0, places)
        
        // Convert all values to Int
        self.multiplier = lrint(fpMultiplier)
        let adjusted = [start, end, stride]
            .map({$0 * fpMultiplier})
            .map(lrint)
        (self.start, self.end, self.stride) =
            (adjusted[0], adjusted[1], adjusted[2])
    }
    
    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Double? {
        if done {
            return nil
        }
        let current = start + iteration * stride; iteration += 1
        if stride > 0 ? current >= end : current <= end {
            if current == end {
                done = true
                // Convert back from Int to Double
                return Double(current) / Double(multiplier)
            }
            return nil
        }
        
        // Convert back from Int to Double
        return Double(current) / Double(multiplier)
    }
}
```

The results with this approach are more precise, enabling errors to drop closer to zero.

```swift
print(Array(1.0.fstride(through: 2.0, by: 0.1)))
print(Array(2.0.fstride(through: 1.0, by: -0.1)))
print(Array((-1.0).fstride(through: -2.0, by: -0.1)))

let ideal = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]
print(zip(Array(1.0.fstride(through: 2.0, by: 0.1)), ideal).map(-))

print(Array(1.0.fstride(through: 2.0, by: 0.005)))

/*
[1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
[2.0, 1.9, 1.8, 1.7, 1.6, 1.5, 1.4, 1.3, 1.2, 1.1, 1.0]
[-1.0, -1.1, -1.2, -1.3, -1.4, -1.5, -1.6, -1.7, -1.8, -1.9, -2.0]
[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
[1.0, 1.005, 1.01, 1.015, 1.02, 1.025, 1.03, 1.035, 1.04, 1.045, 1.05, 1.055, 1.06, 1.065, 1.07, 1.075, 1.08, 1.085, 
1.09, 1.095, 1.1, 1.105, 1.11, 1.115, 1.12, 1.125, 1.13, 1.135, 1.14, 1.145, 1.15, 1.155, 1.16, 1.165, 1.17, 1.175, 
1.18, 1.185, 1.19, 1.195, 1.2, 1.205, 1.21, 1.215, 1.22, 1.225, 1.23, 1.235, 1.24, 1.245, 1.25, 1.255, 1.26, 1.265, 
1.27, 1.275, 1.28, 1.285, 1.29, 1.295, 1.3, 1.305, 1.31, 1.315, 1.32, 1.325, 1.33, 1.335, 1.34, 1.345, 1.35, 1.355, 
1.36, 1.365, 1.37, 1.375, 1.38, 1.385, 1.39, 1.395, 1.4, 1.405, 1.41, 1.415, 1.42, 1.425, 1.43, 1.435, 1.44, 1.445, 
1.45, 1.455, 1.46, 1.465, 1.47, 1.475, 1.48, 1.485, 1.49, 1.495, 1.5, 1.505, 1.51, 1.515, 1.52, 1.525, 1.53, 1.535, 
1.54, 1.545, 1.55, 1.555, 1.56, 1.565, 1.57, 1.575, 1.58, 1.585, 1.59, 1.595, 1.6, 1.605, 1.61, 1.615, 1.62, 1.625, 
1.63, 1.635, 1.64, 1.645, 1.65, 1.655, 1.66, 1.665, 1.67, 1.675, 1.68, 1.685, 1.69, 1.695, 1.7, 1.705, 1.71, 1.715, 
1.72, 1.725, 1.73, 1.735, 1.74, 1.745, 1.75, 1.755, 1.76, 1.765, 1.77, 1.775, 1.78, 1.785, 1.79, 1.795, 1.8, 1.805, 
1.81, 1.815, 1.82, 1.825, 1.83, 1.835, 1.84, 1.845, 1.85, 1.855, 1.86, 1.865, 1.87, 1.875, 1.88, 1.885, 1.89, 1.895, 
1.9, 1.905, 1.91, 1.915, 1.92, 1.925, 1.93, 1.935, 1.94, 1.945, 1.95, 1.955, 1.96, 1.965, 1.97, 1.975, 1.98, 1.985, 
1.99, 1.995, 2.0]
*/
```

#### Calculated Epsilon Values

Computed epsilon values help compare a current value to a floating-point endpoint. 
The following code tests whether the current value lies within 5% of the stride of the endpoint.

```swift
/// A `GeneratorType` for `DoubleStrideThrough`.
public struct DoubleStrideThroughGenerator : GeneratorType {
    let start: Double
    let end: Double
    let stride: Double
    var iteration: Int = 0
    var done: Bool = false
    let epsilon: Double
    
    public init(start: Double, end: Double, stride: Double) {
        (self.start, self.end, self.stride) = (start, end, stride)
        epsilon = self.stride * 0.05 // an arbitrary epsilon of 5% of stride
    }
    
    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Double? {
        if done {
            return nil
        }
        let current = start + Double(iteration) * stride; iteration += 1
        if abs(current - end) < epsilon {
            done = true
            return current
        }
        if signbit(current - end) == signbit(stride) {
            done = true
            return nil
        }
        return current
    }
}
```

#### Other Solutions

While precision math for decimal numbers would be better addressed by introducing a decimal type and/or 
warnings for at-risk floating point numbers, those features lie outside the scope of this proposal.
