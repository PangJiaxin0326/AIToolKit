import Foundation
import FoundationModels
import SwiftUI
import Testing
@testable import AIToolKit

private struct EchoTool: Tool {
    @Generable
    struct Arguments { var text: String }

    @Generable
    struct Output { var echoed: String }

    let name = "echo"
    let description = "Echoes input back."

    func call(arguments: Arguments) async throws -> Output {
        Output(echoed: arguments.text)
    }
}

private struct UppercaseTool: Tool {
    @Generable
    struct Arguments { var text: String }

    @Generable
    struct Output { var uppercased: String }

    let name = "uppercase"
    let description = "Uppercases input text."

    func call(arguments: Arguments) async throws -> Output {
        Output(uppercased: arguments.text.uppercased())
    }
}

private struct SeedTool: Tool, ToolMetadataProviding {
    @Generable
    struct Arguments { var value: String }

    @Generable
    struct Output { var value: String }

    let name = "seed"
    let description = "Returns a seed value."
    let annotations = ToolAnnotations(
        isReadOnly: true,
        isIdempotent: true,
        sideEffect: .none,
        sensitiveOutput: .none
    )

    func call(arguments: Arguments) async throws -> Output {
        Output(value: arguments.value)
    }
}

private struct JoinTool: Tool {
    @Generable
    struct Arguments { var left: String; var right: String }

    @Generable
    struct Output { var combined: String }

    let name = "join"
    let description = "Joins two strings."

    func call(arguments: Arguments) async throws -> Output {
        Output(combined: "\(arguments.left)-\(arguments.right)")
    }
}

@Generable
private struct StringValueOutput {
    var value: String
}

private struct LabelViewTool: ViewTool {
    @Generable
    struct Arguments { var title: String }

    let name = "label"
    let description = "Builds a label view."

    @MainActor
    func call(arguments: Arguments, in context: ToolContext) async throws -> Text {
        Text("\(context.viewID):\(arguments.title)")
    }
}

private func jsonData(_ value: some ConvertibleToGeneratedContent) -> Data {
    Data(value.generatedContent.jsonString.utf8)
}

private func generatedValue<Value: ConvertibleFromGeneratedContent>(
    _ type: Value.Type = Value.self,
    from data: Data
) throws -> Value {
    try Value(GeneratedContent(json: String(decoding: data, as: UTF8.self)))
}

@Suite struct ToolKitRegistryTests {
    @Test func registerAndCall() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let context = ToolContext(viewID: "home")
        let input = jsonData(EchoTool.Arguments(text: "hi"))
        let outData = try await registry.call(
            name: "echo", jsonArguments: input, context: context
        )
        let output = try generatedValue(EchoTool.Output.self, from: outData)
        #expect(output.echoed == "hi")
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
                jsonArguments: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }

    @Test func descriptorPreservesNameAndSchema() throws {
        let tool = EchoTool()
        let descriptor = tool.descriptor
        #expect(descriptor.name == tool.name)
        #expect(descriptor.description == tool.description)
        #expect(try descriptor.argumentsSchema.jsonString().contains("\"text\""))
        guard let outputSchema = descriptor.outputSchema else {
            Issue.record("descriptor must include output schema")
            return
        }
        #expect(try outputSchema.jsonString().contains("\"echoed\""))
    }

    @Test func toolCanUseCallAsFunction() async throws {
        let output = try await EchoTool().callAsFunction(
            EchoTool.Arguments(text: "hi")
        )
        #expect(output.echoed == "hi")
    }

    @Test func toolRegistersAndUsesCallAsFunction() async throws {
        let registry = ToolRegistry()
        await registry.register(UppercaseTool())
        let input = jsonData(UppercaseTool.Arguments(text: "hi"))
        let outData = try await registry.call(
            name: "uppercase",
            jsonArguments: input,
            context: ToolContext(metadata: ["suffix": "!"])
        )
        let output = try generatedValue(UppercaseTool.Output.self, from: outData)
        #expect(output.uppercased == "HI")

        let callableOutput = try await UppercaseTool().callAsFunction(
            UppercaseTool.Arguments(text: "go")
        )
        #expect(callableOutput.uppercased == "GO")
    }

    @Test func generationSchemaObjectHasRequiredFields() throws {
        let schema = try GeneratedContent(json: EchoTool.Arguments.generationSchema.jsonString())
        guard case let .structure(fields, _) = schema.kind else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["type"]?.stringValue == "object")
        #expect(fields["required"]?.allStrings == ["text"])
    }

    @Test func generationSchemaDisallowsAdditionalProperties() throws {
        let schema = try GeneratedContent(json: EchoTool.Arguments.generationSchema.jsonString())
        guard case let .structure(fields, _) = schema.kind else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["additionalProperties"]?.boolValue == false)
    }

    @Test func generatedContentIntValueRejectsUnsafeNumbers() {
        #expect(GeneratedContent.number(42.0).intValue == 42)
        #expect(GeneratedContent.number(42.5).intValue == nil)
        #expect(GeneratedContent.number(Double.greatestFiniteMagnitude).intValue == nil)
    }

    @Test func referenceResolverRejectsNegativeArrayIndex() throws {
        let output: GeneratedContent = .array([.object(["value": .string("ok")])])
        let validInput: GeneratedContent = .object([
            "value": .object(["$ref": .object([
                "source": .string("node"),
                "node": .string("source"),
                "path": .string("/0/value"),
            ])]),
        ])
        let resolved = try WorkflowReferenceResolver.resolve(
            validInput,
            outputs: ["source": output],
            currentNodeID: "consumer"
        )
        #expect(resolved == .object(["value": .string("ok")]))

        let invalidInput: GeneratedContent = .object([
            "value": .object(["$ref": .object([
                "source": .string("node"),
                "node": .string("source"),
                "path": .string("/-1/value"),
            ])]),
        ])
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowReferenceResolver.resolve(
                invalidInput,
                outputs: ["source": output],
                currentNodeID: "consumer"
            )
        }
    }
}

@Suite struct WorkflowKitTests {
    @Test func workflowPromptCatalogIncludesArgumentsAndOutputSchemas() throws {
        let prompt = WorkflowPromptBuilder.planningInstruction(
            toolManifest: [SeedTool().descriptor]
        )
        #expect(prompt.contains("Arguments schema:"))
        #expect(prompt.contains("\"value\""))
        #expect(prompt.contains("Output schema:"))
        #expect(prompt.contains("Side effect: none."))
    }

    @Test func workflowNodesDefaultToTwentySecondTimeout() throws {
        #expect(WorkflowNodePolicy.defaultTimeoutMS == 20_000)
        #expect(WorkflowNodePolicy().timeoutMS == 20_000)
        #expect(WorkflowNode(id: "summarize", tool: "summarizeImageBlock").policy.timeoutMS == 20_000)

        let data = """
        {"id":"summarize","tool":"summarizeImageBlock","input":{}}
        """.data(using: .utf8)!
        let decoded = try WorkflowNode(GeneratedContent(json: String(decoding: data, as: UTF8.self)))
        #expect(decoded.policy.timeoutMS == 20_000)
    }

    @Test func workflowOutputRedactorUsesToolSensitivity() {
        let sensitive = ToolDescriptor(
            name: "sensitive",
            description: "Sensitive output.",
            argumentsSchema: GeneratedContent.generationSchema,
            annotations: ToolAnnotations(sensitiveOutput: .personal)
        )
        let publicOutput = ToolDescriptor(
            name: "public",
            description: "Public output.",
            argumentsSchema: GeneratedContent.generationSchema,
            annotations: ToolAnnotations(sensitiveOutput: .none)
        )
        let value: GeneratedContent = .object(["email": .string("alex@example.com")])
        let node = WorkflowNode(id: "lookup", tool: "sensitive")
        #expect(
            WorkflowOutputRedactor.diagnosticValue(
                value, node: node, descriptor: sensitive
            ) == .object(["email": .string("[REDACTED]")])
        )
        #expect(
            WorkflowOutputRedactor.diagnosticValue(
                value, node: node, descriptor: publicOutput
            ) == value
        )
    }

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
        #expect(result.finalValue.stringValue == "a-b")
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

    @Test func rejectsInvalidLiteralArgumentsAtToolDispatch() async throws {
        let registry = ToolRegistry()
        await registry.register(SeedTool())
        let descriptors = await registry.registeredDescriptors()
        let spec = WorkflowSpec(
            workflowID: "wf_bad_input",
            intent: "Bad literal input.",
            nodes: [
                WorkflowNode(
                    id: "left",
                    tool: "seed",
                    input: .object(["value": .number(1)])
                ),
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

    @Test func rejectsUnknownOutputPathAtExecution() async throws {
        let registry = ToolRegistry()
        await registry.register(SeedTool())
        await registry.register(JoinTool())
        let descriptors = await registry.registeredDescriptors()
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
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(descriptors: descriptors)
        )
        await #expect(throws: WorkflowError.self) {
            _ = try await WorkflowExecutor(registry: registry).execute(validated)
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
                policy: WorkflowValidationPolicy(descriptors: [SeedTool().descriptor])
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

    @Test func executorEnforcesOutputSizeFromGeneratedContentJSON() async throws {
        let spec = WorkflowSpec(
            workflowID: "wf_large_output",
            intent: "Large output.",
            nodes: [
                WorkflowNode(
                    id: "large",
                    tool: "large",
                    outputPolicy: WorkflowOutputPolicy(maxBytes: 8)
                ),
            ],
            final: .message("not reached")
        )
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(availableTools: ["large"])
        )
        let executor = WorkflowExecutor { _, _, _ in
            .object(["value": .string("too long")])
        }
        await #expect(throws: WorkflowError.self) {
            _ = try await executor.execute(validated)
        }
    }
}

@MainActor
@Suite struct ViewToolTests {
    @Test func viewToolRegistryCallsTool() async throws {
        let registry = ViewToolRegistry()
        registry.register(LabelViewTool())
        let input = jsonData(LabelViewTool.Arguments(title: "Hello"))
        let view = try await registry.call(
            name: "label",
            jsonArguments: input,
            context: ToolContext(viewID: "view")
        )
        _ = view
    }

    @Test func viewToolCanUseCallAsFunction() async throws {
        let tool = LabelViewTool()
        let callableView = try await tool.callAsFunction(
            LabelViewTool.Arguments(title: "World"),
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
