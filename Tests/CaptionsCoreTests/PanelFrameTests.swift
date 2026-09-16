import CoreGraphics
import Testing
@testable import CaptionsCore

// 패널 위치·크기 복원과 자동 성장의 화면 clamp 를 검증한다. NSScreen/NSWindow 없이
// CGRect 산수만으로 돈다.

private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

@Test func 저장된_위치와_너비가_화면_안이면_그대로_복원한다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: 100, storedOriginY: 50, storedWidth: 700, visibleFrame: screen)
    #expect(frame == CGRect(x: 100, y: 50, width: 700, height: PanelFrame.minHeight))
}

@Test func 저장값이_없으면_화면_중앙_하단이_기본_위치다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: nil, storedOriginY: nil, storedWidth: nil, visibleFrame: screen)
    #expect(frame.origin == CGPoint(x: screen.midX - PanelFrame.defaultWidth / 2, y: screen.minY + 54))
    #expect(frame.width == PanelFrame.defaultWidth)
}

@Test func 화면_밖_origin은_화면_안으로_당겨진다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: 5000, storedOriginY: 50, storedWidth: 700, visibleFrame: screen)
    #expect(frame.maxX <= screen.maxX)
    #expect(frame.minX >= screen.minX)
    #expect(frame.width == 700)
}

@Test func NaN_origin은_기본_위치로_돌아간다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: Double.nan, storedOriginY: 999, storedWidth: 700, visibleFrame: screen)
    #expect(frame.origin == CGPoint(x: screen.midX - 350, y: screen.minY + 54))
}

@Test func 무한대_origin은_기본_위치로_돌아간다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: Double.infinity, storedOriginY: 50, storedWidth: 700, visibleFrame: screen)
    #expect(frame.origin.x.isFinite)
    #expect(frame.origin == CGPoint(x: screen.midX - 350, y: screen.minY + 54))
}

@Test func 무한대_너비는_기본_너비로_돌아간다() {
    let frame = PanelFrame.restoredFrame(
        storedOriginX: 100, storedOriginY: 50, storedWidth: Double.infinity, visibleFrame: screen)
    #expect(frame.width == PanelFrame.defaultWidth)
    #expect(frame.origin == CGPoint(x: 100, y: 50)) // 유효한 origin은 그대로 쓴다
}

@Test func 화면이_최소_크기보다_작으면_보이는_영역_전체를_채운다() {
    let tinyScreen = CGRect(x: 0, y: 0, width: 400, height: 100)
    let frame = PanelFrame.restoredFrame(
        storedOriginX: nil, storedOriginY: nil, storedWidth: nil, visibleFrame: tinyScreen)
    #expect(frame == tinyScreen)
}

@Test func 화면_위쪽으로_자라도_화면_안에_머문다() {
    // 패널이 화면 꼭대기 근처에 있고 내용이 크게 자란다. 무한정 위로 자라 사라지지 않고
    // 화면 안(바닥이 내려가는 방식으로)에 머물러야 한다.
    let frame = PanelFrame.clamped(
        origin: CGPoint(x: 680, y: 1000), size: CGSize(width: 560, height: 400),
        visibleFrame: screen)
    #expect(frame.maxY <= screen.maxY)
    #expect(frame.minY >= screen.minY)
    #expect(frame.height == 400) // 화면 안에 다 들어가므로 높이는 줄이지 않는다
}

@Test func 화면보다_큰_성장은_보이는_높이로_잘린다() {
    let shortScreen = CGRect(x: 0, y: 0, width: 1920, height: 300)
    let frame = PanelFrame.clamped(
        origin: CGPoint(x: 680, y: 54), size: CGSize(width: 560, height: 5000),
        visibleFrame: shortScreen)
    #expect(frame.maxY <= shortScreen.maxY)
    #expect(frame.minY >= shortScreen.minY)
    #expect(frame.height <= shortScreen.height)
}
