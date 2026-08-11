import { aiLogInfo } from '../../aiphone/runtime/AiphoneLogger';
import { LocalModel } from '../../model/LocalModel';
import { GeneratedPythonToolContract } from './PythonToolContractGenerator';
import { PythonToolScaffold } from './PythonToolScaffoldGenerator';

export const PYTHON_TOOL_CODE_MODEL: string = 'qwen3.7-max';

const MAX_GENERATED_SOURCE_CHARS: number = 32000;
const FORBIDDEN_SOURCE_FRAGMENTS: string[] = [
  '```',
  'def main(',
  'input(',
  'print(',
  'eval(',
  'exec(',
  'compile(',
  'open(',
  '__import__(',
  'globals(',
  'locals(',
  'vars(',
  '__builtins__',
  '__class__',
  '__subclasses__'
];

export const PYTHON_TOOL_CODE_SYSTEM_PROMPT: string =
  'You are the implementation generator for an Appless Python tool.\n\n' +
  'Generate exactly one complete top-level Python function matching requiredFunctionSignature.\n\n' +
  'Return raw Python source only. Do not return Markdown, code fences, JSON, explanations, top-level imports, test ' +
  'code, input(), print(), or a main() function.\n\n' +
  'The generated function will be concatenated with a system-generated main(input) entrypoint. Do not repeat or ' +
  'modify that entrypoint.\n\n' +
  'Implement implementationDescription using only the function parameters and the Python standard library. Do not ' +
  'access the network, filesystem, device APIs, environment variables, global state, or external services. If a ' +
  'standard-library import is necessary, place it inside the function; avoid imports when the behavior can be ' +
  'implemented directly.\n\n' +
  'The function name, parameter names, and parameter order must match requiredFunctionSignature exactly.\n\n' +
  'The function return value must satisfy outputJsonSchema and match outputPropertyOrder. If outputPropertyOrder ' +
  'contains one property, return that property\'s value directly. If it contains multiple properties, return their ' +
  'values as a tuple in exactly that order. Do not return the outer result object because entrypointSource constructs it.';

export interface PythonToolCodeGenerationResult {
  canGenerate: boolean;
  reasonCode: string;
  functionSource: string;
  source: string;
}

interface PythonToolCodeRequestContract {
  domain: string;
  intent: string;
  implementationDescription: string;
  inputJsonSchema: Object;
  outputJsonSchema: Object;
}

interface PythonToolCodeRequestScaffold {
  requiredFunctionSignature: string;
  entrypointSource: string;
  outputPropertyOrder: string[];
}

interface PythonToolCodeRequest {
  contract: PythonToolCodeRequestContract;
  scaffold: PythonToolCodeRequestScaffold;
}

function invalidCodeResult(reasonCode: string = 'INVALID_GENERATED_CODE'): PythonToolCodeGenerationResult {
  return {
    canGenerate: false,
    reasonCode,
    functionSource: '',
    source: ''
  };
}

function generatedFunctionIsValid(raw: string, scaffold: PythonToolScaffold): boolean {
  if (raw.length === 0 || raw.length > MAX_GENERATED_SOURCE_CHARS || raw !== raw.trim()) {
    return false;
  }
  for (let index: number = 0; index < FORBIDDEN_SOURCE_FRAGMENTS.length; index++) {
    if (raw.indexOf(FORBIDDEN_SOURCE_FRAGMENTS[index]) >= 0) {
      return false;
    }
  }
  const lines: string[] = raw.replace(/\r\n/g, '\n').split('\n');
  if (lines.length < 2 || lines[0] !== scaffold.implementationFunctionSignature) {
    return false;
  }
  let hasBody: boolean = false;
  for (let index: number = 1; index < lines.length; index++) {
    if (lines[index].trim().length === 0) {
      continue;
    }
    if (lines[index].indexOf('    ') !== 0) {
      return false;
    }
    hasBody = true;
  }
  return hasBody;
}

function codeRequest(
  contract: GeneratedPythonToolContract,
  scaffold: PythonToolScaffold
): PythonToolCodeRequest {
  const inputJsonSchema = contract.definition.inputJsonSchema;
  if (contract.schemaVersion !== 1 || scaffold.schemaVersion !== 1 || inputJsonSchema === undefined) {
    throw new Error('Python tool contract or scaffold version is not supported.');
  }
  return {
    contract: {
      domain: contract.definition.domain,
      intent: contract.definition.intent,
      implementationDescription: contract.implementationDescription,
      inputJsonSchema: inputJsonSchema as Object,
      outputJsonSchema: contract.outputJsonSchema as Object
    },
    scaffold: {
      requiredFunctionSignature: scaffold.implementationFunctionSignature,
      entrypointSource: scaffold.entrypointSource,
      outputPropertyOrder: scaffold.outputPropertyOrder.slice()
    }
  };
}

export class PythonToolCodeGenerator {
  private readonly model: LocalModel;

  constructor(model: LocalModel) {
    this.model = model;
  }

  async generate(
    contract: GeneratedPythonToolContract,
    scaffold: PythonToolScaffold
  ): Promise<PythonToolCodeGenerationResult> {
    const raw: string = await this.model.complete(
      JSON.stringify(codeRequest(contract, scaffold)),
      undefined,
      PYTHON_TOOL_CODE_SYSTEM_PROMPT,
      {
        includeUsage: true,
        requestTag: 'python-tool-code-generator',
        modelOverride: PYTHON_TOOL_CODE_MODEL
      }
    );
    aiLogInfo('[AIPhone][PythonToolCodeGenerator] phase=model_output raw=' + raw);
    if (!generatedFunctionIsValid(raw, scaffold)) {
      return invalidCodeResult();
    }
    const source: string = raw + '\n\n' + scaffold.entrypointSource + '\n';
    return {
      canGenerate: true,
      reasonCode: '',
      functionSource: raw,
      source
    };
  }
}
