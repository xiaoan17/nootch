import Foundation
import Testing
@testable import Nootch

private let vibeFixtureJSON = """
{
  "buckets": [
    {"source":"claude-code","model":"claude-opus-4-7","project":"unknown","hostname":"Mac","bucketStart":"2026-09-05T08:00:00.000Z","inputTokens":182964,"outputTokens":43966,"cachedInputTokens":4191794,"reasoningOutputTokens":0,"totalTokens":226930,"estimatedCost":4.109867},
    {"source":"claude-code","model":"claude-opus-4-7","project":"unknown","hostname":"Mac","bucketStart":"2026-09-05T09:00:00.000Z","inputTokens":800,"outputTokens":200,"cachedInputTokens":0,"reasoningOutputTokens":0,"totalTokens":1000,"estimatedCost":1.0},
    {"source":"codex","model":"gpt-5","project":"unknown","hostname":"Mac","bucketStart":"2026-09-05T09:30:00.000Z","inputTokens":400,"outputTokens":100,"cachedInputTokens":0,"reasoningOutputTokens":0,"totalTokens":500,"estimatedCost":0.5}
  ],
  "sessions": [
    {"source":"codex","project":"unknown","hostname":"Mac","firstMessageAt":"2026-09-05T08:05:00.000Z","lastMessageAt":"2026-09-05T08:39:26.000Z","durationSeconds":2066,"activeSeconds":2066,"messageCount":314,"userMessageCount":3},
    {"source":"claude-code","project":"unknown","hostname":"Mac","firstMessageAt":"2026-09-05T09:00:00.000Z","lastMessageAt":"2026-09-05T09:01:40.000Z","durationSeconds":100,"activeSeconds":100,"messageCount":10,"userMessageCount":2}
  ],
  "hasAnyData": true
}
"""

private func vibeConfigFile(contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

@Test func vibeSummaryAggregatesBucketsAndSessions() throws {
    let response = try JSONDecoder().decode(VibeUsageAdapter.UsageResponse.self, from: Data(vibeFixtureJSON.utf8))
    let summary = VibeUsageAdapter.summarize(response)
    #expect(abs(summary.totalCostUSD - 5.609867) < 1e-9)
    #expect(summary.totalTokens == 228_430)
    #expect(summary.sessionsCount == 2)
    #expect(summary.activeSeconds == 2166)
    #expect(summary.topModels.count == 2)
    #expect(summary.topModels[0].model == "claude-opus-4-7")
    #expect(abs(summary.topModels[0].costUSD - 5.109867) < 1e-9)
    #expect(summary.topModels[0].tokens == 227_930)
    #expect(summary.topModels[1].model == "gpt-5")
}

@Test func vibeSummaryLimitsTopModelsToFiveByCost() {
    let buckets = (0..<7).map { index in
        "{\"model\":\"model-\(index)\",\"totalTokens\":\(100 - index),\"estimatedCost\":\(Double(index))}"
    }.joined(separator: ",")
    let json = "{\"buckets\":[\(buckets)],\"sessions\":[],\"hasAnyData\":true}"
    let response = try! JSONDecoder().decode(VibeUsageAdapter.UsageResponse.self, from: Data(json.utf8))
    let summary = VibeUsageAdapter.summarize(response)
    #expect(summary.topModels.count == 5)
    #expect(summary.topModels.map(\.model) == ["model-6", "model-5", "model-4", "model-3", "model-2"])
    #expect(summary.sessionsCount == 0)
}

@Test func vibeConfigParsesKeyAndDefaultsURL() throws {
    let config = try #require(VibeUsageAdapter.parseConfig(Data(#"{"apiKey":"vbu_test123","hostname":"Mac"}"#.utf8)))
    #expect(config.apiKey == "vbu_test123")
    #expect(config.apiURL == "https://vibecafe.ai")
}

@Test func vibeConfigUsesExplicitAPIURL() throws {
    let config = try #require(VibeUsageAdapter.parseConfig(Data(#"{"apiKey":"vbu_test123","apiUrl":"http://localhost:4000"}"#.utf8)))
    #expect(config.apiURL == "http://localhost:4000")
}

@Test func vibeConfigRejectsMissingOrEmptyKey() {
    #expect(VibeUsageAdapter.parseConfig(Data(#"{"apiUrl":"https://vibecafe.ai"}"#.utf8)) == nil)
    #expect(VibeUsageAdapter.parseConfig(Data(#"{"apiKey":"  "}"#.utf8)) == nil)
    #expect(VibeUsageAdapter.parseConfig(Data("not json".utf8)) == nil)
}

@Test func vibeDetectRequiresReadableConfig() async throws {
    let missing = VibeUsageAdapter(configPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    #expect(await missing.detect().detected == false)
    let configured = VibeUsageAdapter(configPath: try vibeConfigFile(contents: #"{"apiKey":"vbu_test123"}"#))
    let detection = await configured.detect()
    #expect(detection.detected)
    #expect(detection.source == "vibecafe.ai")
}

@Test func vibeFetchAggregatesTodayUsage() async throws {
    let path = try vibeConfigFile(contents: #"{"apiKey":"vbu_test123"}"#)
    let adapter = VibeUsageAdapter(configPath: path) { request in
        #expect(request.url?.absoluteString == "https://vibecafe.ai/api/usage?days=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer vbu_test123")
        let response = HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(vibeFixtureJSON.utf8), response)
    }
    let status = await adapter.fetch()
    #expect(status.provider == .vibeUsage)
    #expect(status.detected)
    #expect(status.error == nil)
    #expect(status.primary == nil)
    let usage = try #require(status.vibeUsage)
    #expect(usage.totalTokens == 228_430)
    #expect(usage.sessionsCount == 2)
    #expect(usage.topModels.first?.model == "claude-opus-4-7")
}

@Test func vibeFetchReportsInvalidKeyOn401() async throws {
    let path = try vibeConfigFile(contents: #"{"apiKey":"vbu_expired"}"#)
    let adapter = VibeUsageAdapter(configPath: path) { request in
        let response = HTTPURLResponse(url: try #require(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
    let status = await adapter.fetch()
    #expect(status.detected)
    #expect(status.vibeUsage == nil)
    #expect(status.error?.contains("credentials") == true)
}

@Test func cachedStatusWithoutVibeUsageStillDecodes() throws {
    let json = #"{"provider":"claude","detected":true,"activity":"idle"}"#
    let status = try JSONDecoder().decode(ProviderStatus.self, from: Data(json.utf8))
    #expect(status.vibeUsage == nil)
    #expect(status.costUsage == nil)
}
