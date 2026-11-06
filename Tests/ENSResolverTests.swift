import Foundation
import Testing
@testable import ReefrWallet

struct ENSResolverTests {
    @Test func namehashMatchesEIP137Vectors() {
        #expect(ENSResolver.namehash("") == Data(repeating: 0, count: 32))
        #expect(
            ENSResolver.namehash("eth").hexEncoded
                == "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae"
        )
        #expect(
            ENSResolver.namehash("foo.eth").hexEncoded
                == "0xde9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f"
        )
    }

    @Test func namehashIgnoresCase() {
        #expect(ENSResolver.namehash("Foo.ETH") == ENSResolver.namehash("foo.eth"))
    }

    @Test(arguments: ["vitalik.eth", " vitalik.eth ", "sub.name.eth"])
    func acceptsNames(_ input: String) {
        #expect(ENSResolver.isName(input))
    }

    @Test(arguments: ["", "vitalik", "0x1234.5", ".eth", "vitalik..eth", "a b.eth"])
    func rejectsNonNames(_ input: String) {
        #expect(!ENSResolver.isName(input))
    }
}
