import Foundation
import Testing
@testable import SouffleusePersonalization

@Test func ngramReturnsHigherProbForSeenSequence() async {
    let model = NgramModel()
    // (2,3,4) observed twice, (2,3,5) once → denom 3, num(4)=2.
    await model.ingest(tokens: [1, 2, 3, 4])
    await model.ingest(tokens: [1, 2, 3, 4])
    await model.ingest(tokens: [1, 2, 3, 5])
    let seen = await model.bonus(nextToken: 4, given: [2, 3])
    let unseen = await model.bonus(nextToken: 99, given: [2, 3])
    #expect(seen > unseen)
    #expect(seen > 0)        // non-negative bonus for seen n-grams
    #expect(unseen == 0)     // never observed → neutral
}

@Test func ngramReturnsZeroForUnseenContext() async {
    let model = NgramModel()
    await model.ingest(tokens: [1, 2, 3])
    let lp = await model.bonus(nextToken: 99, given: [10, 20])
    #expect(lp == 0)
}

@Test func ngramClearResetsModel() async {
    let model = NgramModel()
    await model.ingest(tokens: [1, 2, 3, 4, 5])
    await model.clear()
    let lp = await model.bonus(nextToken: 4, given: [2, 3])
    #expect(lp == 0)
    let empty = await model.isEmpty
    #expect(empty)
}

@Test func ngramTokenizerTagSwitchClearsModel() async {
    let model = NgramModel(tokenizerTag: "tokA")
    await model.ingest(tokens: [1, 2, 3])
    await model.setTokenizerTag("tokB")
    let empty = await model.isEmpty
    #expect(empty)
}

@Test func ngramBigramFallbackWhenTrigramAbsent() async {
    let model = NgramModel()
    // (2,5) observed twice, (2,6) once → bigram denom 3, num(5)=2.
    await model.ingest(tokens: [1, 2, 5])
    await model.ingest(tokens: [1, 2, 5])
    await model.ingest(tokens: [1, 2, 6])
    // Unseen prevprev → trigram path skips, bigram path applies.
    let lp = await model.bonus(nextToken: 5, given: [42, 2])
    #expect(lp > 0)
}
