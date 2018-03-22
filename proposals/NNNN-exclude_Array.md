# "exclude" in Array

* Proposal: [SE-NNNN](0200-raw-string-escaping.md)
* Authors: [Anantha Krishnan K G](https://github.com/AnanthaKrish)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

I propose adding an `exclude` to `Array`. It excludes the given values from the `Array`.

## Motivation

  this will be helpful to stop using multiple subArrays, like,
  
   ```
   let arrayFirst = ["A","B","C","D","E","F","G"]
   let arraySecond = ["B","C","D"]

   // need all arrayFirst elements
   self.callSomeFunction(arrayFirst)

   // need few arrayFirst elements
   self.callSomeFunction(arraySecond)
  ``` 
  It would be better if we can kepp only one array and use the elemnts which we need only.

## Proposed solution

The proposal suggests a new method - "exclude" in `Array`. The method will create a sub array with only required values.


```
extension Array where Element:Equatable {
    
    func exclude(_ elements:Array) -> Array  {
        
        return self.filter{!elements.contains($0)}
        //return self.filter { (!elements.contains(where: $0 as! (_) throws -> Bool,, }
        //self.filter { !elements.contains(where: $0 as! (_) throws -> Bool)}
    }
}
```

This allows us to write the example above without a second subset of array

   ```
   let arrayFirst = ["A","B","C","D","E","F","G"]
   let arraySecond = ["B","C","D"]

   // need all arrayFirst elements
   self.callSomeFunction(arrayFirst)

   // need few arrayFirst elements
   self.callSomeFunction(arrayFirst.exclude(["B","C","D"]))
  ``` 

## Detailed design

N/A

## Source compatibility

This is strictly additive.

## Effect on ABI stability

N/A.

## Effect on API resilience

N/A

## Alternatives considered

Other names could be:

- `subArray`
- `removeArray`
- `notContains`

