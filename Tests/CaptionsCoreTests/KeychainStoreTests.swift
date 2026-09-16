import Testing
import Foundation
@testable import CaptionsCore

@Test func 저장하고_읽고_지운다() {
    let account = "test.\(UUID().uuidString)"
    defer { KeychainStore.delete(account: account) }

    #expect(KeychainStore.read(account: account) == nil)
    #expect(KeychainStore.save("비밀값", account: account) == true)
    #expect(KeychainStore.read(account: account) == "비밀값")
    #expect(KeychainStore.save("바뀐값", account: account) == true)
    #expect(KeychainStore.read(account: account) == "바뀐값")
    KeychainStore.delete(account: account)
    #expect(KeychainStore.read(account: account) == nil)
}

/// 갱신 경로(`SecItemUpdate`)가 실제로 값을 바꾸는지 별도로 확인한다.
/// 지우고-다시-넣는 구현이었다면 이 테스트 도중 add가 실패해도 드러나지 않았을 것이다 —
/// 여러 번 덮어써서 update 경로를 반복 통과시킨다.
@Test func 여러_번_덮어써도_최신값만_남는다() {
    let account = "test.\(UUID().uuidString)"
    defer { KeychainStore.delete(account: account) }

    #expect(KeychainStore.save("첫값", account: account) == true)
    #expect(KeychainStore.save("둘째값", account: account) == true)
    #expect(KeychainStore.save("셋째값", account: account) == true)
    #expect(KeychainStore.read(account: account) == "셋째값")
}
