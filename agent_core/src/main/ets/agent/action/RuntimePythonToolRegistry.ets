import {
  cloneToolDefinition,
  ToolDefinition
} from '../../aiphone/runtime/ToolDefinitionTypes';

const MAX_SCOPE_ID_CHARS: number = 240;
const MAX_TOOL_ID_CHARS: number = 128;
const MAX_SOURCE_CHARS: number = 131072;

export interface RuntimePythonToolRegistration {
  scopeId: string;
  definition: ToolDefinition;
  source: string;
}

function nonempty(value: string | undefined, maximum: number): boolean {
  return typeof value === 'string' && value.trim().length > 0 &&
    value === value.trim() && value.length <= maximum;
}

function validSource(value: string | undefined): boolean {
  return typeof value === 'string' && value.trim().length > 0 &&
    value.length <= MAX_SOURCE_CHARS;
}

function validRegistration(registration: RuntimePythonToolRegistration): boolean {
  if (registration === null || typeof registration !== 'object' || Array.isArray(registration) ||
    !nonempty(registration.scopeId, MAX_SCOPE_ID_CHARS) ||
    !validSource(registration.source)) {
    return false;
  }
  const definition: ToolDefinition = registration.definition;
  return definition !== null && typeof definition === 'object' && !Array.isArray(definition) &&
    nonempty(definition.toolId, MAX_TOOL_ID_CHARS) && definition.riskLevel === 'read' &&
    definition.inputJsonSchema !== undefined && definition.backendPriority.length > 0 &&
    definition.backendPriority.indexOf('system_intent') < 0 &&
    nonempty(definition.outputSchema, 128) && nonempty(definition.a2uiComponent, 128);
}

function cloneRegistration(
  registration: RuntimePythonToolRegistration
): RuntimePythonToolRegistration {
  return {
    scopeId: registration.scopeId,
    definition: cloneToolDefinition(registration.definition),
    source: registration.source
  };
}

export class RuntimePythonToolRegistry {
  private readonly registrations: Map<string, RuntimePythonToolRegistration> =
    new Map<string, RuntimePythonToolRegistration>();
  private readonly reservedToolIds: Map<string, boolean> = new Map<string, boolean>();

  constructor(reservedToolIds: string[] = []) {
    for (let index: number = 0; index < reservedToolIds.length; index++) {
      const toolId: string = reservedToolIds[index];
      if (nonempty(toolId, MAX_TOOL_ID_CHARS)) {
        this.reservedToolIds.set(toolId, true);
      }
    }
  }

  register(registration: RuntimePythonToolRegistration): boolean {
    if (!validRegistration(registration) ||
      this.reservedToolIds.has(registration.definition.toolId) ||
      this.registrations.has(registration.definition.toolId)) {
      return false;
    }
    this.registrations.set(
      registration.definition.toolId,
      cloneRegistration(registration)
    );
    return true;
  }

  definition(toolId: string): ToolDefinition | null {
    const registration: RuntimePythonToolRegistration | undefined =
      this.registrations.get(toolId);
    return registration === undefined ? null : cloneToolDefinition(registration.definition);
  }

  registration(toolId: string): RuntimePythonToolRegistration | null {
    const registration: RuntimePythonToolRegistration | undefined =
      this.registrations.get(toolId);
    return registration === undefined ? null : cloneRegistration(registration);
  }

  definitions(): ToolDefinition[] {
    const definitions: ToolDefinition[] = [];
    this.registrations.forEach((registration: RuntimePythonToolRegistration) => {
      definitions.push(cloneToolDefinition(registration.definition));
    });
    return definitions;
  }

  removeScope(scopeId: string): void {
    const toolIds: string[] = [];
    this.registrations.forEach((registration: RuntimePythonToolRegistration, toolId: string) => {
      if (registration.scopeId === scopeId) {
        toolIds.push(toolId);
      }
    });
    for (let index: number = 0; index < toolIds.length; index++) {
      this.registrations.delete(toolIds[index]);
    }
  }

  clear(): void {
    this.registrations.clear();
  }
}
