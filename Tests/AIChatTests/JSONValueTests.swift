import AIChat
import Foundation
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    @Test func parsesEveryKind() throws {
        let value = try JSONValue(parsing: #"{"a":1,"b":1.5,"c":true,"d":false,"e":null,"f":"x","g":[1,"two"],"h":{"i":0}}"#)
        #expect(value["a"] == .number(1))
        #expect(value["b"] == .number(1.5))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .bool(false))
        #expect(value["e"] == .null)
        #expect(value["f"] == .string("x"))
        #expect(value["g"] == .array([.number(1), .string("two")]))
        #expect(value["h"]?["i"] == .number(0))
    }

    @Test func keepsBooleansAndNumbersApart() throws {
        let value = try JSONValue(parsing: "[1, 0, true, false]")
        #expect(value == [1, 0, true, false])
    }

    @Test func parsesTopLevelFragments() throws {
        #expect(try JSONValue(parsing: #""hello""#) == "hello")
        #expect(try JSONValue(parsing: "42") == 42)
        #expect(try JSONValue(parsing: "null") == .null)
    }

    @Test func encodesIntegersWithoutFractions() throws {
        let value: JSONValue = ["count": 3, "ratio": 0.25, "big": 1_234_567_890_123]
        #expect(value.jsonString == #"{"big":1234567890123,"count":3,"ratio":0.25}"#)
    }

    @Test func encodesWithSortedKeysAndUnescapedSlashes() {
        let value: JSONValue = ["z": "a/b", "a": ["y": 1, "b": 2]]
        #expect(value.jsonString == #"{"a":{"b":2,"y":1},"z":"a/b"}"#)
    }

    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = ["text": "hi", "list": [1, true, .null, ["nested": "yes"]], "empty": [:]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func decodesIntoTypes() throws {
        struct Weather: Decodable, Equatable { let city: String; let celsius: Int }
        let value: JSONValue = ["city": "Paris", "celsius": 21]
        #expect(try value.decode(Weather.self) == Weather(city: "Paris", celsius: 21))
    }

    @Test func mergesObjectsDeeply() {
        let base: JSONValue = ["threadId": "t1", "usage": ["input": 10, "output": 2], "tags": ["a"]]
        let merged = base.merging(["usage": ["output": 5], "tags": ["b"], "model": "m"])
        #expect(merged == ["threadId": "t1", "usage": ["input": 10, "output": 5], "tags": ["b"], "model": "m"])
    }

    @Test func mergingAPrimitiveReplacesTheBase() {
        #expect(JSONValue.string("a").merging(["b": 1]) == ["b": 1])
        #expect(JSONValue.object(["a": 1]).merging("x") == "x")
    }

    @Test func intValueOnlyForWholeNumbers() {
        #expect(JSONValue.number(4).intValue == 4)
        #expect(JSONValue.number(4.5).intValue == nil)
    }
}
