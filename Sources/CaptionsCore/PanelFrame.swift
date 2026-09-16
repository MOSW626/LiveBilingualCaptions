import CoreGraphics

/// 패널 위치·크기 계산의 순수 로직. `NSScreen`/`NSWindow`에 의존하지 않아 CaptionsCore에서
/// 테스트한다. 높이는 Task 7의 자동 성장(`onGeometryChange`)이 정하므로 저장·복원 대상이
/// 아니다 — 복원은 origin과 width만 쓰고 높이는 최소값에서 시작한다.
public enum PanelFrame {
    // CGFloat로 둔다: Double과 섞어 쓰면 컴파일러의 암묵적 CGFloat/Double 변환에 기대게 되고,
    // swift-testing의 #expect는 그 변환을 타지 않아 값이 같아도 실패로 보인다(실측 확인함).
    public static let minWidth: CGFloat = 560
    public static let minHeight: CGFloat = 188
    public static let defaultWidth: CGFloat = 560

    /// 저장된 origin/width로 시작 프레임을 만든다. 유한하지 않거나 없는 값은 화면 중앙
    /// 하단의 기본 위치로 대체한다. 항상 현재 화면 `visibleFrame` 안으로 clamp 한다.
    public static func restoredFrame(
        storedOriginX: Double?, storedOriginY: Double?, storedWidth: Double?,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = validFinite(storedWidth).map { CGFloat($0) } ?? defaultWidth
        let defaultOrigin = CGPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 54)
        let origin: CGPoint
        if let x = validFinite(storedOriginX), let y = validFinite(storedOriginY) {
            origin = CGPoint(x: x, y: y)
        } else {
            origin = defaultOrigin
        }
        return clamped(origin: origin, size: CGSize(width: width, height: minHeight),
                       visibleFrame: visibleFrame)
    }

    /// 주어진 원점·크기를 화면 `visibleFrame` 안으로 당긴다. 위/오른쪽으로 넘치면 안으로
    /// 밀어 넣는다 — 자동 성장이 화면 위로 넘칠 때도 이 경로를 거쳐 바닥이 내려가며 화면
    /// 안에 머문다. 화면 자체가 최소 크기보다 작으면 보이는 영역 전체를 우선한다.
    public static func clamped(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        var width = min(max(size.width, minWidth), maxWidth)
        var height = min(max(size.height, minHeight), maxHeight)

        var x = min(origin.x, visibleFrame.maxX - width)
        x = max(x, visibleFrame.minX)
        var y = min(origin.y, visibleFrame.maxY - height)
        y = max(y, visibleFrame.minY)

        // 위 clamp로도 화면보다 큰 크기라면(화면이 min 크기보다 작음) 보이는 영역까지만 채운다.
        if x + width > visibleFrame.maxX { width = visibleFrame.maxX - x }
        if y + height > visibleFrame.maxY { height = visibleFrame.maxY - y }
        return CGRect(x: x, y: y, width: max(width, 0), height: max(height, 0))
    }

    private static func validFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
