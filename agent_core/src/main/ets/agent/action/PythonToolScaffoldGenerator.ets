import { ToolInputJsonSchema } from '../../aiphone/runtime/ToolInputJsonSchema';
import { GeneratedPythonToolContract } from './PythonToolContractGenerator';

const IMPLEMENTATION_FUNCTION_NAME: string = 'func';
const PYTHON_KEYWORDS: string[] = [
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
  'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in',
  'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield'
];

export interface PythonToolScaffold {
  schemaVersion: number;
  implementationFunctionName: string;
  implementationFunctionSignature: string;
  outputPropertyOrder: string[];
  entrypointSource: string;
  placeholderSource: string;
}

interface InputBinding {
  propertyName: string;
  variableName: string;
  required: boolean;
}

function objectProperties(schema: ToolInputJsonSchema, label: string): Record<string, ToolInputJsonSchema> {
  if (schema.type !== 'object' || schema.properties === undefined || schema.required === undefined ||
    schema.additionalProperties !== false) {
    throw new Error(`Python tool ${label} schema must be a closed object schema.`);
  }
  const propertyNames: string[] = Object.keys(schema.properties);
  for (let index: number = 0; index < schema.required.length; index++) {
    if (propertyNames.indexOf(schema.required[index]) < 0) {
      throw new Error(`Python tool ${label} schema has an unknown required property.`);
    }
  }
  return schema.properties;
}

function pythonString(value: string): string {
  return JSON.stringify(value);
}

function safePythonIdentifier(propertyName: string, used: string[]): string {
  let candidate: string = propertyName.replace(/[^A-Za-z0-9_]/g, '_');
  if (candidate.length === 0) {
    candidate = 'value';
  }
  if (/^[0-9]/.test(candidate)) {
    candidate = 'value_' + candidate;
  }
  if (PYTHON_KEYWORDS.indexOf(candidate) >= 0 || candidate === 'input' || candidate === 'func') {
    candidate = 'value_' + candidate.toLowerCase();
  }
  const base: string = candidate;
  let suffix: number = 2;
  while (used.indexOf(candidate) >= 0) {
    candidate = base + '_' + suffix.toString();
    suffix++;
  }
  used.push(candidate);
  return candidate;
}

function inputBindings(schema: ToolInputJsonSchema): InputBinding[] {
  const properties: Record<string, ToolInputJsonSchema> = objectProperties(schema, 'input');
  const propertyNames: string[] = Object.keys(properties);
  const required: string[] = schema.required as string[];
  const used: string[] = [];
  const bindings: InputBinding[] = [];
  for (let index: number = 0; index < propertyNames.length; index++) {
    const propertyName: string = propertyNames[index];
    bindings.push({
      propertyName,
      variableName: safePythonIdentifier(propertyName, used),
      required: required.indexOf(propertyName) >= 0
    });
  }
  return bindings;
}

function buildSignature(bindings: InputBinding[]): string {
  const parameters: string[] = [];
  for (let index: number = 0; index < bindings.length; index++) {
    parameters.push(bindings[index].variableName);
  }
  return 'def ' + IMPLEMENTATION_FUNCTION_NAME + '(' + parameters.join(', ') + '):';
}

function buildEntrypoint(
  bindings: InputBinding[],
  outputPropertyNames: string[]
): string {
  const lines: string[] = ['def main(input):'];
  for (let index: number = 0; index < bindings.length; index++) {
    const binding: InputBinding = bindings[index];
    const accessor: string = binding.required ?
      'input[' + pythonString(binding.propertyName) + ']' :
      'input.get(' + pythonString(binding.propertyName) + ')';
    lines.push('    ' + binding.variableName + ' = ' + accessor);
  }
  if (bindings.length > 0) {
    lines.push('');
  }
  const argumentsList: string[] = [];
  for (let index: number = 0; index < bindings.length; index++) {
    argumentsList.push(bindings[index].variableName);
  }
  const call: string = IMPLEMENTATION_FUNCTION_NAME + '(' + argumentsList.join(', ') + ')';
  if (outputPropertyNames.length === 0) {
    lines.push('    ' + call);
    lines.push('    return {}');
    return lines.join('\n');
  }
  if (outputPropertyNames.length === 1) {
    lines.push('    _result = ' + call);
    lines.push('');
    lines.push('    return {');
    lines.push('        ' + pythonString(outputPropertyNames[0]) + ': _result');
    lines.push('    }');
    return lines.join('\n');
  }
  const resultVariables: string[] = [];
  for (let index: number = 0; index < outputPropertyNames.length; index++) {
    resultVariables.push('_result_' + (index + 1).toString());
  }
  lines.push('    ' + resultVariables.join(', ') + ' = ' + call);
  lines.push('');
  lines.push('    return {');
  for (let index: number = 0; index < outputPropertyNames.length; index++) {
    const suffix: string = index + 1 < outputPropertyNames.length ? ',' : '';
    lines.push(
      '        ' + pythonString(outputPropertyNames[index]) + ': ' + resultVariables[index] + suffix
    );
  }
  lines.push('    }');
  return lines.join('\n');
}

export function generatePythonToolScaffold(contract: GeneratedPythonToolContract): PythonToolScaffold {
  if (contract.schemaVersion !== 1 || contract.definition.inputJsonSchema === undefined) {
    throw new Error('Python tool contract is not supported by the scaffold generator.');
  }
  const bindings: InputBinding[] = inputBindings(contract.definition.inputJsonSchema);
  const outputProperties: Record<string, ToolInputJsonSchema> =
    objectProperties(contract.outputJsonSchema, 'output');
  const outputPropertyNames: string[] = Object.keys(outputProperties);
  const signature: string = buildSignature(bindings);
  const entrypoint: string = buildEntrypoint(bindings, outputPropertyNames);
  const placeholder: string = signature + '\n' +
    '    raise NotImplementedError("Implementation not generated.")\n\n' + entrypoint;
  return {
    schemaVersion: 1,
    implementationFunctionName: IMPLEMENTATION_FUNCTION_NAME,
    implementationFunctionSignature: signature,
    outputPropertyOrder: outputPropertyNames.slice(),
    entrypointSource: entrypoint,
    placeholderSource: placeholder
  };
}
