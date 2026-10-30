export class ModelError extends Error {}

export interface ToolCall {
  id?: string;
  name: string;
  args: Record<string, unknown>;
}

export interface ToolResult {
  call: ToolCall;
  result: unknown;
}
