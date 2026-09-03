## Provider-independent read-only tool schemas, policy, requests, and results.

import ../[limits, provider, types]

type
  ToolRisk* = enum
    toolReadOnly

  ToolErrorCode* = enum
    toolOk
    toolInvalidArguments
    toolDisabled
    toolPathDenied
    toolNotFound
    toolNotRegular
    toolBinary
    toolTooLarge
    toolTimedOut
    toolCancelled
    toolIoError
    toolUnknown

  ToolRequest* = object
    id*: ToolCallId
    name*: string
    argumentsJson*: string

  ToolExecutionResult* = object
    requestId*: ToolCallId
    name*: string
    success*: bool
    content*: string
    errorCode*: ToolErrorCode
    errorMessage*: string
    truncated*: bool
    entriesVisited*: int
    matches*: int

  ToolHostPolicy* = object
    workspaceRoot*: string
    enabled*: bool
    limits*: AgentLimits
    cancelled*: proc (): bool {.closure, gcsafe.}

func defaultToolPolicy*(workspaceRoot: string,
    enabled = true): ToolHostPolicy =
  ToolHostPolicy(workspaceRoot: workspaceRoot, enabled: enabled,
    limits: phase1Limits())

func readOnlyToolDefinitions*(): seq[ProviderToolDefinition] =
  @[
    ProviderToolDefinition(name: "list_directory",
      description: "List one workspace directory without recursion.",
      parametersJson: """{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"""),
    ProviderToolDefinition(name: "search_text",
      description: "Search bounded workspace text files for a literal string.",
      parametersJson: """{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string"}},"required":["query"],"additionalProperties":false}"""),
    ProviderToolDefinition(name: "read_file",
      description: "Read a bounded range from one workspace text file.",
      parametersJson: """{"type":"object","properties":{"path":{"type":"string"},"startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1},"lineNumbers":{"type":"boolean"}},"required":["path"],"additionalProperties":false}""")]

func asContentPart*(value: ToolExecutionResult): ContentPart =
  resultPart(ToolResult(callId: value.requestId, name: value.name,
    content: if value.success: value.content else: value.errorMessage,
    success: value.success, truncated: value.truncated,
    errorCode: if value.errorCode == toolOk: "" else: $value.errorCode))
