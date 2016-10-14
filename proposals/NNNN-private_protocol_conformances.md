# Private protocol conformances

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Chris Rutkowski](https://github.com/ChrisRutkowski)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Hiding protocols conformances should be easier.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

In Objective-C any class could easily hide protocol conformances by declaring them in the interface extension in `.m` file of that class. Hiding protocol conformance in Swift requires developer to do additional, not straightforward extra work, however it could be just one liner or even a keyword.

Currently developers either:

- declare protocol conformances that should not be visible to other classes in the class declaration line, what actually... makes the conformances clearly visible to other classes
- we design additional private class, that inherits the protocol and acts as a router between main class and true protocol/delegate

## Example

Let's assume we have a social app. From the search results we go to profile details (`ProfileVC`). Search View Controller is required to pass `Profile` object to `ProfileVC` and should not know how `ProfileVC` handles the presentation. For this example let's assume the `ProfileVC` has multiple tabs - about, photos, friends.

Code:

	protocol TabBarDelegate: class {
		func tabBar(_ tabBar: TabBar, didSelectTabAtIndex index: Int)
	}

	class ProfileVC: UIViewController, TabBarDelegate, SomeOtherProtocol {
		var profile: Profile!
		@IBOutlet private var tabBar: TabBar!
		
		// other code
		
		func tabBar(tabBar: TabBar, didSelectTabAtIndex index: Int) {
			// change child view controller
		}
	}

Problem:

Other classes (assuming above implementation) have ability to call the `TabBarDelegate`'s method.

	let vc = ProfileVC()
	vc.profile = profiles[5]
	vc.tabBar(TabBar(), didSelectTabAtIndex: 1)
	
## Proposed solution

Either this new concept:

	class ProfileVC: UIViewController, private TabBarDelegate, SomeOtherProtocol

or using existing language features:

	private extension ProfileVC: TabBarDelegate
	
but it actually causes compilation error: _'private' modifier cannot be used with extensions that declare protocol conformances_.

## Detailed design

Either:

	protocol TabBarDelegate: class {
		func tabBar(_ tabBar: TabBar, didSelectTabAtIndex index: Int)
	}

	class ProfileVC: UIViewController, private TabBarDelegate, SomeOtherProtocol {
		var profile: Profile!
		@IBOutlet private var tabBar: TabBar!
		
		// other code
		
		private func tabBar(tabBar: TabBar, didSelectTabAtIndex index: Int) {
			// change child view controller
		}
	}

or:

	protocol TabBarDelegate: class {
		func tabBar(_ tabBar: TabBar, didSelectTabAtIndex index: Int)
	}

	class ProfileVC: UIViewController, SomeOtherProtocol {
		var profile: Profile!
		@IBOutlet private var tabBar: TabBar!
		
		// other code
	}
	
	private extension ProfileVC: TabBarDelegate {

		func tabBar(tabBar: TabBar, didSelectTabAtIndex index: Int) {
			// update UI code
		}
	}
	