import XCTest
#if SWIFT_PACKAGE
@testable import WatchGPTCore
#else
@testable import WatchGPTPhone
#endif

final class OpenAIParsingTests: XCTestCase {
    func testOutputTextConvenienceField() {
        XCTAssertEqual(OpenAIResponseParsing.outputText(from: ["output_text": "hello"]), "hello")
    }

    func testOutputTextStructuredWalk() {
        let json: [String: Any] = [
            "output": [
                ["content": [["text": "part one"], ["text": " part two"]]]
            ]
        ]
        XCTAssertEqual(OpenAIResponseParsing.outputText(from: json), "part one part two")
    }

    func testOutputTextEmptyOrMissingReturnsNil() {
        XCTAssertNil(OpenAIResponseParsing.outputText(from: ["output_text": "   "]))
        XCTAssertNil(OpenAIResponseParsing.outputText(from: [:]))
        XCTAssertNil(OpenAIResponseParsing.outputText(from: ["output": []]))
    }

    func testWebSearchCallCount() {
        let json: [String: Any] = [
            "output": [
                ["type": "web_search_call"],
                ["type": "message"],
                ["type": "web_search_call"]
            ]
        ]
        XCTAssertEqual(OpenAIResponseParsing.webSearchCallCount(in: json), 2)
        XCTAssertEqual(OpenAIResponseParsing.webSearchCallCount(in: [:]), 0)
    }

    func testNonFatalErrorClassification() {
        let benign = RealtimeErrorClassifier.parse([
            "error": ["message": "Cancellation failed: no active response found"]
        ])
        XCTAssertTrue(RealtimeErrorClassifier.isNonFatal(benign))

        let commitEmpty = RealtimeErrorClassifier.parse([
            "type": "error",
            "code": "input_audio_buffer_commit_empty",
            "message": "buffer is empty"
        ])
        XCTAssertTrue(RealtimeErrorClassifier.isNonFatal(commitEmpty))
    }

    func testFatalErrorClassification() {
        let fatal = RealtimeErrorClassifier.parse([
            "error": ["message": "Invalid API key provided", "code": "invalid_api_key"]
        ])
        XCTAssertFalse(RealtimeErrorClassifier.isNonFatal(fatal))
    }

    func testErrorParsePrefersNestedThenTopLevel() {
        XCTAssertEqual(RealtimeErrorClassifier.parse(["error": ["message": "nested"]]).message, "nested")
        XCTAssertEqual(RealtimeErrorClassifier.parse(["message": "top"]).message, "top")
        XCTAssertEqual(RealtimeErrorClassifier.parse([:]).message, "OpenAI realtime error")
    }

    func testHallucinationFilterFlagsStockPhrases() {
        XCTAssertTrue(ThinkTranscriptFilter.isLikelyHallucination("Thank you."))
        XCTAssertTrue(ThinkTranscriptFilter.isLikelyHallucination("  thanks for watching  "))
        XCTAssertTrue(ThinkTranscriptFilter.isLikelyHallucination(""))
        XCTAssertTrue(ThinkTranscriptFilter.isLikelyHallucination("You"))
    }

    func testHallucinationFilterKeepsRealSpeech() {
        XCTAssertFalse(ThinkTranscriptFilter.isLikelyHallucination("What's the weather in Paris?"))
        XCTAssertFalse(ThinkTranscriptFilter.isLikelyHallucination("Thank you for the detailed explanation"))
    }
}
