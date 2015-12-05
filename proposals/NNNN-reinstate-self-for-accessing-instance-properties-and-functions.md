# Re-instate mandatory self for accessing instance properties and functions  

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-mandatory-self-for-accessing-instance-properties-and-functions.md)
* Author(s): [David Hart](https://github.com/hartbit)
* Status: **Review**
* Review manager: TBD

## Introduction

Swift used to force using `self.` when accessing instance properties and functions, but since dropped this requirement (only keeping it for closure captures). It now feels inconsistent, and we have lost the automatic documentation of instance properties vs local variables and instance functions vs local functions or closures. This proposal offers to re-instate the original behaviour.

## Motivation

The previous behaviour which this proposal hopes to re-instate makes it obvious which are instance properties vs local variables, as well as which are instance functions vs local functions/closures. This has several advantages:

* More readabile at the point of use. 
* More consistent than only requiring `self` in closure contexts.
* Less confusing from a learning point of view.
* Lets the compiler warn users (and avoids bugs) where the authors mean to use a local variable but instead are unknowingly using an instance property (and the other way round).

One example of a bug avoided by the original proposal ([provided by Rudolf Adamkovic](https://lists.swift.org/pipermail/swift-evolution/2015-December/000243.html)):

```
class MyViewController : UIViewController {
	@IBOutlet var button: UIButton!
        var name: String = “David"

	func updateButton() {
		// var title = “Hello \(name)”
		button.setTitle(title, forState: .Normal) // forgot to comment this line but the compiler does not complain and title is now referencing UIViewController’s title by mistake
		button.setTitleColor(UIColor.blackColor(), forState: .Normal)
	}
}
```

The API Design Guidelines are meant for writing APIs but I still think they represent fundamentals of Swift. The two first points are:

* Clarity at the point of use is your most important goal. Code is read far more than it is written.
* Clarity is more important than brevity. Although Swift code can be compact, it is a non-goal to enable the smallest possible code with the fewest characters. Brevity in Swift code, where it occurs, is a side-effect of the strong type system and features that naturally reduce boilerplate.

And I believe that the proposition is directly in line with those objectives.

## Proposed Solution

I suggest that not using `self` for accessing instance properties and functions is applied in two stages. In Swift 2.x, it could start as a warning and Xcode could provide a Fix-It. Then, it could become a compiler error in Swift 3 and the migrator would help transition code over.  

## Impact on existing code

A lot of code written since the original change would be impacted by this proposal, but it seems like it can be easily fixed by both the migrator tool and an Xcode Fix-It.

## Alternatives considered

The alternative is to keep the current behaviour, but it has the aforementioned disadvantages.

## Community Responses

* "I actually encountered at least two bugs in my app introduced by this implicit "self" behavior. It can be dangerous and hard to track down." -- Rudolf Adamkovic, salutis@me.com
* "Given this, some teams use underscores for their iVars which is very unfortunate. Myself, I use self whenever possible to be explicit. I'd like the language to force us to be clear." -- Dan, robear18@gmail.com
* "I'm not sure how many Swift users this effects, but I'm colorblind and I really struggle with the local vs properties syntax coloring." -- Tyler Cloutier, cloutiertyler@aol.com
* "+1 I've had a lot of weird things happen that I've traced to mistakes in properties having the same name as function arguments. I've hardly ever had this issue in modern Obj-C." -- Coli Cornaby, colin.cornaby@mac.com
* "Teaching wise, its much less confusing for self to be required so students don't mix up instance properties and local vars. Especially when self is required in closures, it confuses students. If self is mandatory for all instance properties, it would be so much clearer and much easier to read." -- Yichen Cao, ycao@me.com
* "I'm +1 on this, for the reasons already stated by others, but not as strongly as I was a year ago. I was very worried about this with Swift 1 was first released, but since then, I haven't actually made this mistake, possibly because I'm so paranoid about it." -- Michael Buckley, michael@buckleyisms.com