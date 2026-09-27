//
//  TestTypeAliases.swift
//  ProxyTunnelCoreTests
//
//  `import Network` also brings an `IPAddress` into scope in this SDK, so an
//  unqualified `IPAddress` in the test target is ambiguous. An internal
//  typealias declared in the test module wins over both imports and resolves it
//  once, for every file.
//

import Foundation
@testable import ProxyTunnelCore

typealias IPAddress = ProxyTunnelCore.IPAddress
typealias IPNetwork = ProxyTunnelCore.IPNetwork
