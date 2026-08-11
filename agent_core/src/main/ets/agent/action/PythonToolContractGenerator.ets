import { LocalModel } from '../../model/LocalModel';
import {
  ToolDefinition
} from '../../aiphone/runtime/ToolDefinitionTypes';
import {
  ToolInputJsonSchema,
  ToolInputJsonSchemaType
} from '../../aiphone/runtime/ToolInputJsonSchema';
import { aiLogInfo } from '../../aiphone/runtime/AiphoneLogger';

export const PYTHON_TOOL_CONTRACT_MODEL: string = 'qwen3.7-max';

const MAX_GOAL_CHARS: number = 240;
const MAX_TEXT_CHARS: number = 4000;
const MAX_SCHEMA_DEPTH: number = 12;
const SUPPORTED_SCHEMA_TYPES: ToolInputJsonSchemaType[] = [
  'object', 'array', 'string', 'number', 'integer', 'boolean', 'null'
];
const SCHEMA_KEYS: string =
  'additionalProperties,description,enum,items,maximum,minLength,minimum,properties,required,type';

export const PYTHON_TOOL_CONTRACT_SYSTEM_PROMPT: string =
  'You are the Appless Python tool contract generator. ' +
  'Given one natural-language goal, produce a contract for the narrowest reusable Python tool that can solve this ' +
  'goal and other requests of the same kind. Treat the supplied goal as one example invocation, not as the ' +
  'permanent definition of the tool. Generalize concrete values and naturally variable choices into input ' +
  'parameters. Do not embed values from the current invocation in schema descriptions, enum values, implementation ' +
  'rules, or output fields merely because they appear in the goal. Keep the capability focused. Do not add unrelated ' +
  'operations, optional features, external data sources, or capability variants that are not needed by the goal. ' +
  'For example, for "convert 26 degrees Celsius to Fahrenheit", the numeric value and the source and target units ' +
  'should be input parameters, but an unrelated temperature unit does not need to be added. ' +
  'Set canGenerate=true only when the capability can be implemented as a deterministic, standalone, read-only ' +
  'Python program using only its structured input and the Python standard library. It must not require network ' +
  'access, current external data, files, device APIs, user interaction, another tool\'s output, or side effects. ' +
  'Otherwise, return canGenerate=false. Return exactly one JSON object with exactly these fields: canGenerate, ' +
  'reasonCode, contract. For a successful result, canGenerate must be true, reasonCode must be the empty string, ' +
  'and contract must contain exactly domain, intent, inputJsonSchema, outputJsonSchema, and ' +
  'implementationDescription. domain and intent must be concise lowercase English identifiers describing the ' +
  'reusable capability. inputJsonSchema must describe every value required to execute the tool independently. ' +
  'outputJsonSchema must describe the complete structured result. implementationDescription must describe the ' +
  'general deterministic behavior and necessary calculation rules precisely enough for a later code generator, but ' +
  'must not contain Python code or values belonging only to the current invocation. A valid success object has this ' +
  'exact structural shape: {"canGenerate":true,"reasonCode":"","contract":{"domain":"math",' +
  '"intent":"square","inputJsonSchema":{"type":"object","description":"A number to square.",' +
  '"properties":{"value":{"type":"number","description":"The number to square."}},' +
  '"required":["value"],"additionalProperties":false},"outputJsonSchema":{"type":"object",' +
  '"description":"The square result.","properties":{"result":{"type":"number",' +
  '"description":"The squared value."}},"required":["result"],"additionalProperties":false},' +
  '"implementationDescription":"Multiply the input value by itself."}}. Use the same field structure, but infer the ' +
  'reusable capability and schemas from the supplied goal. Both schemas must use one of ' +
  'these types: object, array, string, number, integer, boolean, null. The root and every nested schema node must have ' +
  'a non-empty description. The root type must be object. Every object must define properties, required, and ' +
  'additionalProperties=false. required may list only existing property names. Arrays must define items. Use enum, ' +
  'minimum, maximum, and minLength only when they are inherent constraints of the reusable capability. Do not use ' +
  'unsupported JSON Schema keywords. Do not generate invocation arguments, Python source code, toolId, UI metadata, ' +
  'runtime metadata, suggested-action IDs, task IDs, defaults, markdown, explanations, or additional fields. For an ' +
  'unsupported result, return exactly {"canGenerate":false,"reasonCode":"UNSUPPORTED_BY_PYTHON","contract":null}.';

export interface GeneratedPythonToolContract {
  schemaVersion: number;
  definition: ToolDefinition;
  outputJsonSchema: ToolInputJsonSchema;
  implementationDescription: string;
}

export interface PythonToolContractGenerationResult {
  canGenerate: boolean;
  reasonCode: string;
  contract: GeneratedPythonToolContract | null;
}

export type GeneratedPythonToolIdProvider = () => string;

interface PythonToolContractDraft {
  domain: string;
  intent: string;
  inputJsonSchema: ToolInputJsonSchema;
  outputJsonSchema: ToolInputJsonSchema;
  implementationDescription: string;
}

interface PythonToolContractModelResult {
  canGenerate: boolean;
  reasonCode: string;
  contract: PythonToolContractDraft | null;
}

let generatedToolSequence: number = 0;

function nextGeneratedToolId(): string {
  generatedToolSequence++;
  return 'python.generated.' + Date.now().toString() + '.' + generatedToolSequence.toString();
}

function nonemptyText(value: string | undefined, maximum: number = MAX_TEXT_CHARS): boolean {
  return typeof value === 'string' && value.trim().length > 0 &&
    value === value.trim() && value.length <= maximum;
}

function validEnumValueForType(value: Object | string | number | boolean | null, type: string): boolean {
  if (type === 'string') {
    return typeof value === 'string';
  }
  if (type === 'number') {
    return typeof value === 'number' && Number.isFinite(value);
  }
  if (type === 'integer') {
    return typeof value === 'number' && Number.isInteger(value);
  }
  if (type === 'boolean') {
    return typeof value === 'boolean';
  }
  if (type === 'null') {
    return value === null;
  }
  if (type === 'array') {
    return Array.isArray(value);
  }
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function validSchemaEnum(schema: ToolInputJsonSchema): boolean {
  if (schema.enum === undefined) {
    return true;
  }
  if (!Array.isArray(schema.enum) || schema.enum.length === 0) {
    return false;
  }
  for (let index: number = 0; index < schema.enum.length; index++) {
    if (!validEnumValueForType(schema.enum[index] as Object | string | number | boolean | null, schema.type)) {
      return false;
    }
  }
  return true;
}

function validNumericKeywords(schema: ToolInputJsonSchema): boolean {
  if (schema.minimum !== undefined &&
    (typeof schema.minimum !== 'number' || !Number.isFinite(schema.minimum))) {
    return false;
  }
  if (schema.maximum !== undefined &&
    (typeof schema.maximum !== 'number' || !Number.isFinite(schema.maximum))) {
    return false;
  }
  return schema.minimum === undefined || schema.maximum === undefined ||
    schema.minimum <= schema.maximum;
}

function validRequiredKeys(schema: ToolInputJsonSchema, propertyKeys: string[]): boolean {
  if (schema.required === undefined || !Array.isArray(schema.required)) {
    return false;
  }
  const seen: string[] = [];
  for (let index: number = 0; index < schema.required.length; index++) {
    const key: string = schema.required[index];
    if (!nonemptyText(key, 128) || propertyKeys.indexOf(key) < 0 || seen.indexOf(key) >= 0) {
      return false;
    }
    seen.push(key);
  }
  return true;
}

function validToolSchema(value: Object, depth: number = 0): boolean {
  if (depth > MAX_SCHEMA_DEPTH || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const keys: string = Object.keys(value).sort().join(',');
  const allowedKeys: string[] = SCHEMA_KEYS.split(',');
  const actualKeys: string[] = keys.length === 0 ? [] : keys.split(',');
  for (let index: number = 0; index < actualKeys.length; index++) {
    if (allowedKeys.indexOf(actualKeys[index]) < 0) {
      return false;
    }
  }
  const schema: ToolInputJsonSchema = value as ToolInputJsonSchema;
  if (SUPPORTED_SCHEMA_TYPES.indexOf(schema.type) < 0 || !nonemptyText(schema.description)) {
    return false;
  }
  if (!validSchemaEnum(schema) || !validNumericKeywords(schema)) {
    return false;
  }
  if (schema.minLength !== undefined &&
    (typeof schema.minLength !== 'number' || !Number.isInteger(schema.minLength) || schema.minLength < 0)) {
    return false;
  }
  if (schema.type === 'object') {
    if (schema.properties === undefined || schema.properties === null ||
      typeof schema.properties !== 'object' || Array.isArray(schema.properties) ||
      schema.additionalProperties !== false || schema.items !== undefined ||
      schema.minimum !== undefined || schema.maximum !== undefined || schema.minLength !== undefined) {
      return false;
    }
    const propertyKeys: string[] = Object.keys(schema.properties);
    if (!validRequiredKeys(schema, propertyKeys)) {
      return false;
    }
    for (let index: number = 0; index < propertyKeys.length; index++) {
      const propertyName: string = propertyKeys[index];
      if (!nonemptyText(propertyName, 128) ||
        !validToolSchema(schema.properties[propertyName] as Object, depth + 1)) {
        return false;
      }
    }
    return true;
  }
  if (schema.properties !== undefined || schema.required !== undefined ||
    schema.additionalProperties !== undefined) {
    return false;
  }
  if (schema.type === 'array') {
    return schema.items !== undefined && schema.minimum === undefined &&
      schema.maximum === undefined && schema.minLength === undefined &&
      validToolSchema(schema.items as Object, depth + 1);
  }
  if (schema.items !== undefined) {
    return false;
  }
  if (schema.type === 'string') {
    return schema.minimum === undefined && schema.maximum === undefined;
  }
  if (schema.type === 'number' || schema.type === 'integer') {
    return schema.minLength === undefined;
  }
  return schema.minimum === undefined && schema.maximum === undefined && schema.minLength === undefined;
}

function invalidResult(reasonCode: string): PythonToolContractGenerationResult {
  return {
    canGenerate: false,
    reasonCode,
    contract: null
  };
}

export class PythonToolContractGenerator {
  private readonly model: LocalModel;
  private readonly toolIdProvider: GeneratedPythonToolIdProvider;

  constructor(model: LocalModel, toolIdProvider?: GeneratedPythonToolIdProvider) {
    this.model = model;
    this.toolIdProvider = toolIdProvider === undefined ? nextGeneratedToolId : toolIdProvider;
  }

  async generate(goal: string): Promise<PythonToolContractGenerationResult> {
    if (!nonemptyText(goal, MAX_GOAL_CHARS)) {
      throw new Error('Python tool contract goal is invalid.');
    }
    const raw: string = await this.model.complete(
      JSON.stringify({ goal, outputFormat: 'JSON' }),
      undefined,
      PYTHON_TOOL_CONTRACT_SYSTEM_PROMPT,
      {
        includeUsage: true,
        requestTag: 'python-tool-contract-generator',
        modelOverride: PYTHON_TOOL_CONTRACT_MODEL
      }
    );
    aiLogInfo('[AIPhone][PythonToolContractGenerator] phase=model_output raw=' + raw);
    return this.parse(raw);
  }

  private parse(raw: string): PythonToolContractGenerationResult {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw.trim()) as Object;
    } catch (_error) {
      return invalidResult('INVALID_CONTRACT');
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
      Object.keys(parsed).sort().join(',') !== 'canGenerate,contract,reasonCode') {
      return invalidResult('INVALID_CONTRACT');
    }
    const modelResult: PythonToolContractModelResult = parsed as PythonToolContractModelResult;
    if (modelResult.canGenerate === false) {
      return modelResult.contract === null && modelResult.reasonCode === 'UNSUPPORTED_BY_PYTHON' ?
        invalidResult('UNSUPPORTED_BY_PYTHON') : invalidResult('INVALID_CONTRACT');
    }
    if (modelResult.canGenerate !== true || modelResult.reasonCode !== '' ||
      modelResult.contract === null || typeof modelResult.contract !== 'object' ||
      Array.isArray(modelResult.contract) ||
      Object.keys(modelResult.contract).sort().join(',') !==
        'domain,implementationDescription,inputJsonSchema,intent,outputJsonSchema') {
      return invalidResult('INVALID_CONTRACT');
    }
    const draft: PythonToolContractDraft = modelResult.contract;
    if (!nonemptyText(draft.domain, 80) || !nonemptyText(draft.intent, 120) ||
      !nonemptyText(draft.implementationDescription) ||
      !validToolSchema(draft.inputJsonSchema as Object) ||
      !validToolSchema(draft.outputJsonSchema as Object) ||
      draft.inputJsonSchema.type !== 'object' || draft.outputJsonSchema.type !== 'object') {
      return invalidResult('INVALID_CONTRACT');
    }
    const toolId: string = this.toolIdProvider();
    if (!nonemptyText(toolId, 128) || toolId.indexOf('python.generated.') !== 0) {
      return invalidResult('INVALID_CONTRACT');
    }
    return {
      canGenerate: true,
      reasonCode: '',
      contract: {
        schemaVersion: 1,
        definition: {
          toolId,
          domain: draft.domain,
          intent: draft.intent,
          riskLevel: 'read',
          backendPriority: ['local_adapter'],
          authModes: ['none'],
          inputSchema: 'pythonGeneratedInputV1',
          inputJsonSchema: draft.inputJsonSchema,
          outputSchema: 'genericToolResults',
          a2uiComponent: 'GenericToolResults',
          actions: []
        },
        outputJsonSchema: draft.outputJsonSchema,
        implementationDescription: draft.implementationDescription
      }
    };
  }
}
