import AIChat
import Testing

/// Cases ported from the AI SDK's `fix-json.test.ts`.
@Suite("PartialJSON")
struct PartialJSONTests {
    static let repairCases: [(String, String)] = [
        ("", ""),
        ("nul", "null"),
        ("t", "true"),
        ("fals", "false"),
        ("12.", "12"),
        ("12.2", "12.2"),
        ("-12", "-12"),
        ("-", ""),
        ("2.5e", "2.5"),
        ("2.5e-", "2.5"),
        ("2.5e3", "2.5e3"),
        ("-2.5e3", "-2.5e3"),
        ("2.5E", "2.5"),
        ("2.5E-", "2.5"),
        ("2.5E3", "2.5E3"),
        ("-2.5E3", "-2.5E3"),
        ("12.e", "12"),
        ("12.34e", "12.34"),
        ("5e", "5"),
        (#""abc"#, #""abc""#),
        (#""value with \"quoted\" text and \\ escape"#, #""value with \"quoted\" text and \\ escape""#),
        (#""value with \"#, #""value with ""#),
        (#""\u"#, #""""#),
        (#""\u12"#, #""""#),
        (#""text \u00"#, #""text ""#),
        (#"{"a":"\u12"#, #"{"a":""}"#),
        (#""value with unicode <""#, #""value with unicode <""#),
        ("[", "[]"),
        ("[[1], [2", "[[1], [2]]"),
        (#"[["1"], ["2"#, #"[["1"], ["2"]]"#),
        ("[[false], [nu", "[[false], [null]]"),
        ("[[[]], [[]", "[[[]], [[]]]"),
        ("[[{}], [{", "[[{}], [{}]]"),
        ("[1, ", "[1]"),
        ("[[], 123", "[[], 123]"),
        (#"{"key":"#, "{}"),
        (#"{"a": {"b": 1}, "c": {"d": 2"#, #"{"a": {"b": 1}, "c": {"d": 2}}"#),
        (#"{"a": {"b": "1"}, "c": {"d": 2"#, #"{"a": {"b": "1"}, "c": {"d": 2}}"#),
        (#"{"a": {"b": false}, "c": {"d": 2"#, #"{"a": {"b": false}, "c": {"d": 2}}"#),
        (#"{"a": {"b": []}, "c": {"d": 2"#, #"{"a": {"b": []}, "c": {"d": 2}}"#),
        (#"{"a": {"b": {}}, "c": {"d": 2"#, #"{"a": {"b": {}}, "c": {"d": 2}}"#),
        (#"{"ke"#, "{}"),
        (#"{"k1": 1, "k2"#, #"{"k1": 1}"#),
        (#"{"k1": 1, "k2":"#, #"{"k1": 1}"#),
        (#"{"key": "value"  "#, #"{"key": "value"}"#),
        (#"{"a": {"b": {}"#, #"{"a": {"b": {}}}"#),
        ("[1, [2, 3, [", "[1, [2, 3, []]]"),
        ("[false, [true, [", "[false, [true, []]]"),
        (#"{"key": {"subKey":"#, #"{"key": {}}"#),
        (#"{"key": 123, "key2": {"subKey":"#, #"{"key": 123, "key2": {}}"#),
        (#"{"key": null, "key2": {"subKey":"#, #"{"key": null, "key2": {}}"#),
        (#"{"key": [1, 2, {"#, #"{"key": [1, 2, {}]}"#),
        (#"[1, 2, {"key": "value","#, #"[1, 2, {"key": "value"}]"#),
        (#"{"a": {"b": ["c", {"d": "e","#, #"{"a": {"b": ["c", {"d": "e"}]}}"#),
        (#"{"a": {"b": {"c": {"d":"#, #"{"a": {"b": {"c": {}}}}"#),
        (#"{"a": 1, "b": ["#, #"{"a": 1, "b": []}"#),
        (#"{"a": 1, "b": {"#, #"{"a": 1, "b": {}}"#),
        (#"{"a": 1, "b": ""#, #"{"a": 1, "b": ""}"#),
        (
            "{\n  \"a\": [\n    {\n      \"a1\": \"v1\",\n      \"a2\": \"v2\",\n      \"a3\": \"v3\"\n    }\n  ],\n  \"b\": [\n    {\n      \"b1\": \"n",
            "{\n  \"a\": [\n    {\n      \"a1\": \"v1\",\n      \"a2\": \"v2\",\n      \"a3\": \"v3\"\n    }\n  ],\n  \"b\": [\n    {\n      \"b1\": \"n\"}]}"
        ),
        (#"{"type":"div","children":[{"type":"Card","props":{}"#, #"{"type":"div","children":[{"type":"Card","props":{}}]}"#),
    ]

    @Test(arguments: repairCases)
    func repairsLikeTheAISDK(input: String, expected: String) {
        #expect(PartialJSON.repair(input) == expected)
    }

    @Test func parsesCompleteJSONWithoutRepair() {
        let result = PartialJSON.parse(#"{"city":"Paris"}"#)
        #expect(result.state == .successfulParse)
        #expect(result.value == ["city": "Paris"])
    }

    @Test func repairsStreamingToolInput() {
        let result = PartialJSON.parse(#"{"city":"Par"#)
        #expect(result.state == .repairedParse)
        #expect(result.value == ["city": "Par"])
    }

    @Test func reportsMissingInput() {
        #expect(PartialJSON.parse(nil).state == .undefinedInput)
        #expect(PartialJSON.parse(nil).value == nil)
    }

    @Test func keepsMultibyteCharactersWhole() {
        #expect(PartialJSON.parse(#"{"note":"café 🍰"#).value == ["note": "café 🍰"])
    }
}
