# Service Manager Extension

* Proposal: [swiftsm](swiftpm-swift-service-extension.md)
* Authors: [Amr Aboelela](https://github.com/amraboelela)
* Review Manager:
* Status:
* Implementation: 

## Introduction

This proposal suggests to create swift service manager extension of swiftpm, in which developers can publish services which depend of each other. Each service has a protocol and an implementation. the consumers of thoses services can import them into their project target as is, or they can replace one or more service implementations down the line. The swift frameworks should provide a ServiceProvider class to provide the current implementation of any required service in the runtime. This can be decided during the build process.

## Motivation

This will increase the usuability of developers modules, after splitting them into services, when we split libraries into smaller building blocks which can be used as is without modifications, or we can replace any service (module) as needed, even if the service is down the heirarchy levels.

The current swiftpm imbed (copies) packages under our own project, which makes it difficult to make changes to those libraries. The suggested solution will encourage developers to split their liraries into smalled building blocks called services with 2 parts (interface, and implementation), they would provide their default implementation for each service, while the consumer project can choose to use the default implementation or create his/her own implementation, and publish it for other developers to use.

This would make open source projects more productive and colarable. Also for private company projects can make their projects more scalable and productive.

## Proposed solution

Create an extension of swiftpm, to handle services, including the defintion of modules as service, their dependencies of each other, how to overide the implementation of existing service down the line of dependencies, etc.


## Detailed design

I'll leave this part for Apple folks / swift community to decide once it is approved.

## Alternatives considered

No alternatives were considered for now.
