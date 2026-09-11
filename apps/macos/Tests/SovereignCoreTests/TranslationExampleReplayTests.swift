import XCTest
@testable import SovereignCore

/// P2-2 (2026-09-11): a near copy of the T5 example target for an unrelated
/// source is a replay, not a translation. Pairs are the ones measured on the
/// 0.3.25/0.3.26 Korean bundles.
final class TranslationExampleReplayTests: XCTestCase {
    func testLyricTranslationReplayedUnderAnUnrelatedSource() {
        let ex = "マイケンの助けが広がるショートカット、アミが作られた四つの夢の道五日"
        XCTAssertTrue(TranslationOutputPolicy.isExampleReplay(ex + "。",
            exampleTarget: ex, source: "엄마가 나를 믿고 도와주니까 내가 꼭 성공을 해야겠다 어머니가 행복하셨으면",
            exampleSource: "마이큰 보탬이 펼쳐있는 지름길 아미 빚어진 네 꿈의 길 오일"))
    }
    func testNearCopyIsAReplay() {
        let ex = "因此，移动这些点并逐渐加入噪声，使其完全变成一个球体，这是第一步；接下来再去掉噪声。"
        let out = "因此，移动这些点并逐渐加入噪声，使其完全变成一个球体，这是第一步；接下来去掉噪声"
        XCTAssertTrue(TranslationOutputPolicy.isExampleReplay(out, exampleTarget: ex,
            source: "그리고 얘는 노이즈를 계속 없애요.", exampleSource: "그럼 이 점들을 옮기고 노이즈를 조금씩 넣어서 완전히 공처럼 만드는 게 첫 단계고"))
    }
    func testSameSentenceReTranslationIsKept() {
        let ex = "During the pandemic, we filmed how people in cities kept their distance."
        XCTAssertFalse(TranslationOutputPolicy.isExampleReplay(ex, exampleTarget: ex,
            source: "코로나 때 사회적 거리두기 같은 걸 하기 위해서 도시에서 사람들이 어떻게",
            exampleSource: "코로나 때 사회적 거리두기 같은 걸 하기 위해서 도시에서 사람들이"))
    }
    func testShortExampleIsNeverAReplay() {
        XCTAssertFalse(TranslationOutputPolicy.isExampleReplay("是的。", exampleTarget: "是的。", source: "Yes.", exampleSource: "Yeah."))
    }
    func testARealTranslationIsNotAReplay() {
        XCTAssertFalse(TranslationOutputPolicy.isExampleReplay("So, I've combined the consultation room and the treatment room.",
            exampleTarget: "I've been thinking about beauty, but in any case, I wanted peace of mind and body.",
            source: "그래서 이제 제가 진료실이랑 처치 시술실을 좀 같이 몰아놓기는 했거든요.",
            exampleSource: "뷰티를 좀 생각을 하고 있지만 어쨌든 마음에서도 피스 인 마인드"))
    }
    func testSimilarityBounds() {
        XCTAssertEqual(TranslationOutputPolicy.similarity("abc def", "abc def"), 1, accuracy: 1e-9)
        XCTAssertLessThan(TranslationOutputPolicy.similarity("완전히 다른 문장입니다", "another sentence entirely"), 0.2)
    }
}
