import Testing
@testable import WalletKit

struct WalletKitTests {
    @Test func helloWorldReturnsGreeting() async throws {
        #expect(helloWorld() == "Hello, World!")
    }
}
