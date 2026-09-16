import SwiftUI
import Translation
import CaptionsCore

struct CaptionOverlay: View {
    let state: CaptionState
    var onToggle: () -> Void
    var onClear: () -> Void
    var onCycleLanguage: () -> Void
    var onCycleAudioSource: () -> Void
    var onQuit: () -> Void
    /// 내용 높이를 창에게 알린다. 자막이 쌓이면 창이 위로 자라야 한다.
    var onHeight: (CGFloat) -> Void
    /// 리사이즈 핸들 드래그 중. 제스처 시작점부터의 누적 수평 이동량(포인트)을 매
    /// 갱신마다 넘긴다 — 델타가 아니라 누적값이라 호출자가 드래그 시작 시점의 폭에
    /// 그대로 더하면 된다(작은 델타를 계속 누적하면 반올림 오차가 쌓인다).
    var onResizeChanged: (CGFloat) -> Void
    /// 드래그가 끝났다. 다음 드래그가 그 시점의 실제 폭에서 다시 시작하도록 호출자가
    /// 기준값을 지우는 신호다.
    var onResizeEnded: () -> Void

    /// 언어팩이 없으면 이 설정이 non-nil 이 되고, .translationTask 가 다운로드 시트를 띄운다.
    /// SwiftUI 로 그리는 이유가 이 한 줄이다.
    @State private var downloadConfiguration: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 7) {
            // 최근 발화를 쌓아 보여준다. 최신이 아래, 가장 밝게. 위로 갈수록 흐려진다.
            ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                let age = state.entries.count - 1 - index      // 0 = 최신
                let dim = max(0.35, 1.0 - Double(age) * 0.28)
                VStack(spacing: 3) {
                    Text(entry.original)
                        .font(.system(size: state.fontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(dim))
                    if !entry.translated.isEmpty {
                        Text(entry.translated)
                            .font(.system(size: state.fontSize * 0.8, weight: .medium))
                            .foregroundStyle(.white.opacity(dim * 0.72))
                            .animation(.easeInOut(duration: 0.2), value: entry.translated)
                    }
                }
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            if state.isEmpty {
                Text("말을 시작하면 자막이 여기에 표시됩니다")
                    .font(.system(size: state.fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Text(state.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Button(state.audioSourceName, action: onCycleAudioSource)
                Button(state.languageTitle, action: onCycleLanguage)
                Button(state.toggleTitle, action: onToggle)
                    .disabled(!state.canToggle)
                Button("지우기", action: onClear)
                Button("종료", action: onQuit)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        // 기준 커밋의 NSVisualEffectView(.hudWindow) 는 **어두운** 재질이다. 밝은 재질 위의
        // 흰 자막은 밝은 배경 앱 위에서 대비를 잃는다 — 이 앱이 하는 유일한 일이 읽히는
        // 것이므로 밝기를 환경에 맡기지 않고 어둡게 고정한다.
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 20))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        // 부수효과: 아래 .bordered 버튼들도 어두운 테마(밝은 글자)로 바뀐다. 의도한 것이다 —
        // 어두운 HUD 위의 버튼이라 그게 맞다. "밝은 테마로 되돌리는" 수정을 하지 말 것.
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        // 창이 아직 줄어들기 전이라면 자막은 아래에 붙어 있는다.
        .frame(maxHeight: .infinity, alignment: .bottom)
        // 시트에서 사용자가 받기를 누르면 prepareTranslation() 이 완료된다.
        // 클로저를 @Sendable 로 잡아 비격리로 만든다: session 은 비격리 API 라
        // 메인 액터에 묶인 값으로 넘기면 Swift 6 이 sending 위반으로 막는다.
        .translationTask(downloadConfiguration) { @Sendable session in
            try? await session.prepareTranslation()
        }
        .task(id: "\(state.sourceLanguage.id)-\(state.targetLanguage.id)") {
            await requestPackIfNeeded()
        }
        // 리사이즈 핸들. 패널이 `.borderless`라 시스템 리사이즈 가장자리가 없다 — 이
        // 손잡이가 유일한 드래그-리사이즈 진입점이다. 모서리에 작게 둔다: 다른 사람의
        // 발표 위에 떠 있는 창이라 화려하면 안 되지만, 완전히 숨으면 리사이즈가 가능한지
        // 아무도 모른다. 히트 영역은 아이콘보다 넉넉히(패딩 8pt) 둬서 작은 아이콘이라도
        // 잡기 쉽게 한다. 배경 어디든 클릭하면 `isMovableByWindowBackground`가 창을
        // 옮기는 것과 달리, 이 아이콘 위 클릭은 여기 붙은 제스처가 먼저 가져가므로
        // 창 이동과 부딪히지 않는다(버튼들과 같은 원리).
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onResizeChanged($0.translation.width) }
                        .onEnded { _ in onResizeEnded() }
                )
                .help("드래그해서 패널 폭 조절")
        }
    }

    @MainActor
    private func requestPackIfNeeded() async {
        // 먼저 비운다. Configuration 은 Equatable 이라, 팩이 필요한 언어쌍으로 되돌아왔을 때
        // 값이 같은 설정을 다시 넣으면 SwiftUI 가 변화를 못 보고 시트를 띄우지 않는다.
        // 이 nil 은 아래 await 를 건너 관측되고, .installed 로 밝혀진 쌍도 이 줄이 정리한다.
        downloadConfiguration = nil
        // .installed 면 할 일이 없고, .unsupported 면 시트를 띄워도 받을 게 없다.
        guard await Translator.packStatus(from: state.sourceLanguage,
                                          to: state.targetLanguage) == .needsDownload else { return }
        downloadConfiguration = TranslationSession.Configuration(
            source: state.sourceLanguage.locale.language,
            target: state.targetLanguage.locale.language)
    }
}
