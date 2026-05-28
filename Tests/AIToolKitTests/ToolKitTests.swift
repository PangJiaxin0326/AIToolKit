import Foundation
import SwiftUI
import Testing
@testable import AIToolKit

private struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back."
    static let inputSchema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(echoed: "\(context.viewID):\(input.text)")
    }
}

private struct UppercaseTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var uppercased: String }

    static let name = "uppercase"
    static let description = "Uppercases input text."
    static let inputSchema = ToolSchema.object(
        properties: ["text": .string(description: "text to uppercase")],
        required: ["text"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(uppercased: input.text.uppercased() + (context.metadata["suffix"] ?? ""))
    }
}

private struct SeedTool: Tool {
    struct Input: Codable, Sendable { var value: String }
    struct Output: Codable, Sendable { var value: String }

    static let name = "seed"
    static let description = "Returns a seed value."
    static let inputSchema = ToolSchema.object(
        properties: ["value": .string],
        required: ["value"]
    )
    static let outputSchema = ToolSchema.strictObject(
        properties: ["value": .string],
        required: ["value"]
    )
    static let annotations = ToolAnnotations(
        isReadOnly: true,
        isIdempotent: true,
        sideEffect: .none,
        sensitiveOutput: .none
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(value: input.value)
    }
}

private struct JoinTool: Tool {
    struct Input: Codable, Sendable { var left: String; var right: String }
    struct Output: Codable, Sendable { var combined: String }

    static let name = "join"
    static let description = "Joins two strings."
    static let inputSchema = ToolSchema.object(
        properties: ["left": .string, "right": .string],
        required: ["left", "right"]
    )
    static let outputSchema = ToolSchema.strictObject(
        properties: ["combined": .string],
        required: ["combined"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(combined: "\(input.left)-\(input.right)")
    }
}

private struct BadOutputTool: Tool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { var value: Int }

    static let name = "bad_output"
    static let description = "Returns output that does not match its schema."
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(
        properties: ["value": .string],
        required: ["value"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(value: 42)
    }
}

private struct LabelViewTool: ViewTool {
    struct Input: Codable, Sendable { var title: String }

    static let name = "label"
    static let description = "Builds a label view."
    static let inputSchema = ToolSchema.object(
        properties: ["title": .string(description: "label title")],
        required: ["title"]
    )

    @MainActor
    func call(_ input: Input, in context: ToolContext) async throws -> Text {
        Text("\(context.viewID):\(input.title)")
    }
}

@Suite struct ToolKitRegistryTests {
    @Test func registerAndCall() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let context = ToolContext(viewID: "home")
        let input = try JSONEncoder().encode(EchoTool.Input(text: "hi"))
        let outData = try await registry.call(
            name: "echo", jsonInput: input, context: context
        )
        let output = try JSONDecoder().decode(EchoTool.Output.self, from: outData)
        #expect(output.echoed == "home:hi")
    }

    @Test func manifestSubsetting() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let subset = await registry.manifest(for: ["echo"])
        #expect(subset.map(\.name) == ["echo"])
        let empty = await registry.manifest(for: [])
        #expect(empty.isEmpty)
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.call(
                name: "nope",
                jsonInput: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }

    @Test func descriptorPreservesNameAndSchema() {
        let descriptor = EchoTool.descriptor
        #expect(descriptor.name == EchoTool.name)
        #expect(descriptor.description == EchoTool.description)
        #expect(descriptor.inputSchema == EchoTool.inputSchema.json)
        #expect(descriptor.outputSchema == EchoTool.outputSchema.json)
    }

    @Test func toolCanUseCallAsFunction() async throws {
        let output = try await EchoTool().callAsFunction(
            EchoTool.Input(text: "hi"),
            in: ToolContext(viewID: "home")
        )
        #expect(output.echoed == "home:hi")
    }

    @Test func toolRegistersAndUsesCallAsFunction() async throws {
        let registry = ToolRegistry()
        await registry.register(UppercaseTool())
        let input = try JSONEncoder().encode(UppercaseTool.Input(text: "hi"))
        let outData = try await registry.call(
            name: "uppercase",
            jsonInput: input,
            context: ToolContext(metadata: ["suffix": "!"])
        )
        let output = try JSONDecoder().decode(UppercaseTool.Output.self, from: outData)
        #expect(output.uppercased == "HI!")

        let callableOutput = try await UppercaseTool().callAsFunction(
            UppercaseTool.Input(text: "go"),
            in: ToolContext(metadata: ["suffix": "."])
        )
        #expect(callableOutput.uppercased == "GO.")
    }

    @Test func toolSchemaObjectHasRequiredFields() {
        let schema = ToolSchema.object(
            properties: ["a": .string],
            required: ["a"]
        )
        guard case let .object(fields) = schema.json else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["type"] == .string("object"))
        #expect(fields["required"] == .array([.string("a")]))
    }

    @Test func strictObjectDisallowsAdditionalProperties() {
        let schema = ToolSchema.strictObject(
            properties: ["a": .string],
            required: ["a"]
        )
        guard case let .object(fields) = schema.json else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["additionalProperties"] == .bool(false))
    }
}

@Suite struct WorkflowKitTests {
    @Test func validatesAndExecutesWorkflowDAG() async throws {
        let registry = ToolRegistry()
        await registry.register(SeedTool())
        await registry.register(JoinTool())
        let descriptors = await registry.registeredDescriptors()
        let spec = WorkflowSpec(
            workflowID: "wf_join",
            intent: "Join two values.",
            nodes: [
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .string("a")])
                ),
                WorkflowNode(
                    id: "right",
                    tool: "seed",
                    input: .object(["value": .string("b")])
                ),
                WorkflowNode(
                    id: "join_values",
                    tool: "join",
                    input: .object([
                        "left": .object(["$ref": .object([
                            "source": .string("node"),
                            "node": .string("left"),
                            "path": .string("/value"),
                        ])]),
                        "right": .object(["$ref": .object([
                            "source": .string("node"),
                            "node": .string("right"),
                            "path": .string("/value"),
                        ])]),
                    ])
                ),
            ],
            final: .nodeOutput("join_values", path: "/combined"),
            limits: WorkflowLimits(maxNodes: 5, maxParallelism: 2)
        )

        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(descriptors: descriptors)
        )
        #expect(validated.levels.map { $0.map(\.id).sorted() } == [
            ["left", "right"], ["join_values"],
        ])

        let result = try await WorkflowExecutor(registry: registry)
            .execute(validated)
        #expect(result.finalText == "a-b")
        #expect(result.finalValue == .string("a-b"))
        #expect(result.nodeOutputs.keys.sorted() == ["join_values", "left", "right"])
    }

    @Test func rejectsForwardReferences() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_bad",
            intent: "Bad order.",
            nodes: [
                WorkflowNode(
                    id: "join_values",
                    tool: "join",
                    input: .object([
                        "left": .object(["$ref": .object([
                            "source": .string("node"),
                            "node": .string("left"),
                            "path": .string("/value"),
                        ])]),
                    ])
                ),
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .string("a")])
                ),
            ],
            final: .nodeOutput("join_values")
        )
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowValidator.validate(
                spec,
                policy: WorkflowValidationPolicy(
                    availableTools: ["seed", "join"]
                )
            )
        }
    }

    @Test func rejectsInvalidLiteralInputAgainstToolSchema() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_bad_input",
            intent: "Bad literal input.",
            nodes: [
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .int(1)])
                ),
            ],
            final: .message("not reached")
        )
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowValidator.validate(
                spec,
                policy: WorkflowValidationPolicy(descriptors: [SeedTool.descriptor])
            )
        }
    }

    @Test func rejectsUnknownOutputSchemaPath() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_bad_path",
            intent: "Bad reference path.",
            nodes: [
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .string("a")])
                ),
                WorkflowNode(
                    id: "join_values",
                    tool: "join",
                    input: .object([
                        "left": .object(["$ref": .object([
                            "source": .string("node"),
                            "node": .string("left"),
                            "path": .string("/missing"),
                        ])]),
                        "right": .string("b"),
                    ])
                ),
            ],
            final: .nodeOutput("join_values", path: "/combined")
        )
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowValidator.validate(
                spec,
                policy: WorkflowValidationPolicy(
                    descriptors: [SeedTool.descriptor, JoinTool.descriptor]
                )
            )
        }
    }

    @Test func rejectsFinalReferenceToNonExposedNode() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_private_final",
            intent: "Try to expose hidden output.",
            nodes: [
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .string("secret")]),
                    outputPolicy: WorkflowOutputPolicy(exposeToFinal: false)
                ),
            ],
            final: .nodeOutput("left", path: "/value")
        )
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowValidator.validate(
                spec,
                policy: WorkflowValidationPolicy(descriptors: [SeedTool.descriptor])
            )
        }
    }

    @Test func executorSkipsDependentsWhenPolicyRequestsIt() async throws {
        let spec = WorkflowSpec(
            workflowID: "wf_skip",
            intent: "Skip dependents.",
            nodes: [
                WorkflowNode(
                    id: "source",
                    tool: "source",
                    policy: WorkflowNodePolicy(onError: .skipDependents)
                ),
                WorkflowNode(
                    id: "dependent",
                    tool: "dependent",
                    dependsOn: ["source"]
                ),
            ],
            final: .message("Done.")
        )
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(availableTools: ["source", "dependent"])
        )
        let executor = WorkflowExecutor { node, _, _ in
            if node.id == "source" {
                throw GenericToolError(message: "source failed")
            }
            Issue.record("dependent should have been skipped")
            return .object([:])
        }
        let result = try await executor.execute(validated)
        #expect(result.finalText == "Done.")
        #expect(result.trace.nodes.map(\.status).contains(.skipped))
    }

    @Test func executorEnforcesNodeTimeout() async throws {
        let spec = WorkflowSpec(
            workflowID: "wf_timeout",
            intent: "Timeout slow node.",
            nodes: [
                WorkflowNode(
                    id: "slow",
                    tool: "slow",
                    policy: WorkflowNodePolicy(timeoutMS: 5)
                ),
            ],
            final: .message("not reached")
        )
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(availableTools: ["slow"])
        )
        let executor = WorkflowExecutor { _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return .object([:])
        }
        await #expect(throws: WorkflowError.self) {
            _ = try await executor.execute(validated)
        }
    }

    @Test func executorValidatesOutputSchema() async throws {
        let registry = ToolRegistry()
        await registry.register(BadOutputTool())
        let descriptors = await registry.registeredDescriptors()
        let spec = WorkflowSpec(
            workflowID: "wf_bad_output",
            intent: "Bad output.",
            nodes: [
                WorkflowNode(id: "bad", tool: BadOutputTool.name),
            ],
            final: .message("not reached")
        )
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(descriptors: descriptors)
        )
        await #expect(throws: WorkflowError.self) {
            _ = try await WorkflowExecutor(registry: registry).execute(validated)
        }
    }
}

@MainActor
@Suite struct ViewToolTests {
    @Test func viewToolRegistryCallsTool() async throws {
        let registry = ViewToolRegistry()
        registry.register(LabelViewTool())
        let input = try JSONEncoder().encode(LabelViewTool.Input(title: "Hello"))
        let view = try await registry.call(
            name: "label",
            jsonInput: input,
            context: ToolContext(viewID: "view")
        )
        _ = view
    }

    @Test func viewToolCanUseCallAsFunction() async throws {
        let tool = LabelViewTool()
        let callableView = try await tool.callAsFunction(
            LabelViewTool.Input(title: "World"),
            in: ToolContext(viewID: "view")
        )
        _ = callableView
    }
}

@Suite struct ToolContextTests {
    @Test func defaultsAreEmpty() {
        let context = ToolContext()
        #expect(context.viewID == "")
        #expect(context.metadata.isEmpty)
    }

    @Test func metadataRoundTrips() {
        let context = ToolContext(viewID: "x", metadata: ["entryID": "1"])
        #expect(context.metadata["entryID"] == "1")
    }
}
