import Foundation
import Testing
@testable import TVCore

/// P2-21：Doubao 预设 model 曾为空，导致按它拼出的请求永远无法完成。
/// 每个已知 provider 都必须带一个可用的 model，且 Doubao 是它自己的默认。
struct SubtitleTranslatorTests {
    @Test func everyKnownProviderCarriesAUsableModel() {
        for provider in SubtitleTranslator.Provider.known {
            #expect(!provider.model.isEmpty, "\(provider.name) has no model")
        }
        #expect(SubtitleTranslator.Provider.known.first { $0.name == "Doubao" }?.model == "doubao-pro-32k")
    }
}
