import {
  aiLogInfo,
  allToolDefinitions,
  ConversationContext,
  generatePythonToolScaffold,
  LocalModel,
  LocalModelCompletionOptions,
  PreparedActionDraft,
  PythonToolCodeGenerationResult,
  PythonToolCodeGenerator,
  PythonToolContractGenerationResult,
  PythonToolContractGenerator,
  PythonToolScaffold,
  registerGeneratedPythonTool,
  RuntimePythonToolRegistration,
  RuntimePythonToolRegistry,
  ToolDefinition
} from '@loop/agent-core';
import { DEMO_TEMPERATURE_CONTRACT } from './DemoPythonToolScaffoldTest';
import { MultiAgentSuggestedActionPreparer } from './MultiAgentSuggestedActionPreparer';

const PIPELINE_GOAL: string = '帮用户把26摄氏度的气温转化为华氏度的气温';
const LOG_CHUNK_CHARS: number = 1800;

function logChunks(marker: string, value: string): void {
  const partCount: number = Math.max(1, Math.ceil(value.length / LOG_CHUNK_CHARS));
  for (let index: number = 0; index < partCount; index++) {
    aiLogInfo(marker + ' part=' + (index + 1).toString() + '/' + partCount.toString() +
      ' data=' + value.substring(index * LOG_CHUNK_CHARS, (index + 1) * LOG_CHUNK_CHARS));
  }
}

function logObject(marker: string, value: Object): void {
  try {
    logChunks(marker, JSON.stringify(value));
  } catch (error) {
    aiLogInfo(marker + ' serialization=failed error=' + `${error}`);
  }
}

class PipelineProbeModel implements LocalModel {
  private readonly delegate: LocalModel;
  readonly suggestedPrompts: string[] = [];

  constructor(delegate: LocalModel) {
    this.delegate = delegate;
  }

  async complete(
    prompt: string,
    conversation?: ConversationContext,
    systemPrompt?: string,
    options?: LocalModelCompletionOptions
  ): Promise<string> {
    const requestTag: string = options?.requestTag ?? '';
    if (requestTag === 'suggested-action-preparer') {
      this.suggestedPrompts.push(prompt);
      logChunks(
        '[AIPhone][PythonPipelineDevice][SolidifierPrompt] call=' +
          this.suggestedPrompts.length.toString(),
        prompt
      );
    }
    const response: string = await this.delegate.complete(
      prompt,
      conversation,
      systemPrompt,
      options
    );
    logChunks(
      '[AIPhone][PythonPipelineDevice][ModelResponse] tag=' +
        (requestTag.length === 0 ? 'untagged' : requestTag),
      response
    );
    return response;
  }
}

function standardCodeResult(scaffold: PythonToolScaffold): PythonToolCodeGenerationResult {
  const functionSource: string =
    'def func(value, fromUnit, toUnit):\n' +
      '    if fromUnit == toUnit:\n' +
      '        return value\n' +
      '    if fromUnit == "celsius":\n' +
      '        celsius = value\n' +
      '    elif fromUnit == "fahrenheit":\n' +
      '        celsius = (value - 32) * 5 / 9\n' +
      '    else:\n' +
      '        celsius = value - 273.15\n' +
      '    if toUnit == "celsius":\n' +
      '        return celsius\n' +
      '    if toUnit == "fahrenheit":\n' +
      '        return celsius * 9 / 5 + 32\n' +
      '    return celsius + 273.15';
  return {
    canGenerate: true,
    reasonCode: '',
    functionSource,
    source: functionSource + '\n\n' + scaffold.entrypointSource + '\n'
  };
}

async function runIsolatedModuleTests(model: LocalModel): Promise<void> {
  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=contract status=started');
  const contractResult: PythonToolContractGenerationResult =
    await new PythonToolContractGenerator(model).generate(PIPELINE_GOAL);
  logObject('[AIPhone][PythonPipelineDevice][Module] name=contract output', contractResult as Object);
  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=contract status=' +
    (contractResult.canGenerate && contractResult.contract !== null ? 'passed' : 'failed'));

  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=scaffold status=started');
  const scaffold: PythonToolScaffold = generatePythonToolScaffold(DEMO_TEMPERATURE_CONTRACT);
  logObject('[AIPhone][PythonPipelineDevice][Module] name=scaffold output', scaffold as Object);
  const scaffoldOk: boolean = scaffold.implementationFunctionSignature ===
    'def func(value, fromUnit, toUnit):' &&
    scaffold.entrypointSource.indexOf('def main(input):') >= 0;
  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=scaffold status=' +
    (scaffoldOk ? 'passed' : 'failed'));

  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=code status=started');
  const codeResult: PythonToolCodeGenerationResult =
    await new PythonToolCodeGenerator(model).generate(DEMO_TEMPERATURE_CONTRACT, scaffold);
  logObject('[AIPhone][PythonPipelineDevice][Module] name=code output', codeResult as Object);
  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=code status=' +
    (codeResult.canGenerate && codeResult.source.indexOf('def main(input):') >= 0 ? 'passed' : 'failed'));

  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=assembler status=started');
  const assemblerRegistry = new RuntimePythonToolRegistry();
  const assemblerCode: PythonToolCodeGenerationResult = standardCodeResult(scaffold);
  const assemblerRegistered: boolean = registerGeneratedPythonTool(
    assemblerRegistry,
    DEMO_TEMPERATURE_CONTRACT,
    assemblerCode
  );
  const assemblerRegistration: RuntimePythonToolRegistration | null =
    assemblerRegistry.registration(DEMO_TEMPERATURE_CONTRACT.definition.toolId);
  if (assemblerRegistration !== null) {
    logObject(
      '[AIPhone][PythonPipelineDevice][Module] name=assembler output',
      assemblerRegistration as Object
    );
  }
  aiLogInfo('[AIPhone][PythonPipelineDevice][Module] name=assembler status=' +
    (assemblerRegistered && assemblerRegistration !== null ? 'passed' : 'failed'));
}

function matchingDefinitionShape(left: ToolDefinition, right: ToolDefinition): boolean {
  return Object.keys(left).sort().join(',') === Object.keys(right).sort().join(',');
}

function inspectSolidifierExposure(
  prompt: string,
  registry: RuntimePythonToolRegistry
): boolean {
  let parsed: Record<string, Object | string>;
  try {
    parsed = JSON.parse(prompt) as Record<string, Object | string>;
  } catch (error) {
    aiLogInfo('[AIPhone][PythonPipelineDevice][Exposure] status=failed reason=prompt_parse error=' +
      `${error}`);
    return false;
  }
  const registeredTools = parsed['registeredTools'] as ToolDefinition[];
  if (!Array.isArray(registeredTools)) {
    aiLogInfo('[AIPhone][PythonPipelineDevice][Exposure] status=failed reason=tools_missing');
    return false;
  }
  let generated: ToolDefinition | null = null;
  let existing: ToolDefinition | null = null;
  for (let index: number = 0; index < registeredTools.length; index++) {
    if (registeredTools[index].toolId.indexOf('python.generated.') === 0) {
      generated = registeredTools[index];
    }
    if (registeredTools[index].toolId === 'hotel.search') {
      existing = registeredTools[index];
    }
  }
  if (generated === null || existing === null) {
    aiLogInfo('[AIPhone][PythonPipelineDevice][Exposure] status=failed reason=definition_missing');
    return false;
  }
  logObject('[AIPhone][PythonPipelineDevice][Exposure] generatedTool', generated as Object);
  logObject('[AIPhone][PythonPipelineDevice][Exposure] existingTool', existing as Object);
  const registration: RuntimePythonToolRegistration | null =
    registry.registration(generated.toolId);
  const sameShape: boolean = matchingDefinitionShape(generated, existing);
  const sourceHidden: boolean = registration !== null &&
    prompt.indexOf(registration.source) < 0 && prompt.indexOf('def func(') < 0 &&
    prompt.indexOf('def main(input):') < 0;
  aiLogInfo('[AIPhone][PythonPipelineDevice][Exposure] status=' +
    (sameShape && sourceHidden ? 'passed' : 'failed') +
    ' sameDefinitionShape=' + (sameShape ? 'true' : 'false') +
    ' sourceHidden=' + (sourceHidden ? 'true' : 'false') +
    ' toolCount=' + registeredTools.length.toString() +
    ' generatedTool=' + generated.toolId);
  return sameShape && sourceHidden;
}

async function runChainedTest(model: LocalModel): Promise<void> {
  aiLogInfo('[AIPhone][PythonPipelineDevice][Chain] status=started goal=' + PIPELINE_GOAL);
  const staticTools: ToolDefinition[] = allToolDefinitions();
  const registry = new RuntimePythonToolRegistry(
    staticTools.map((definition: ToolDefinition): string => definition.toolId)
  );
  const probe = new PipelineProbeModel(model);
  const preparer = new MultiAgentSuggestedActionPreparer(
    probe,
    staticTools,
    (): string => '2026-08-11',
    registry
  );
  const prepared: PreparedActionDraft = await preparer.prepare(PIPELINE_GOAL);
  logObject('[AIPhone][PythonPipelineDevice][Chain] prepared', prepared as Object);
  const definitions: ToolDefinition[] = registry.definitions();
  logObject('[AIPhone][PythonPipelineDevice][Chain] runtimeDefinitions', definitions as Object);
  const retried: boolean = probe.suggestedPrompts.length === 2;
  const ready: boolean = prepared.canImplement && prepared.steps.length === 1 &&
    prepared.steps[0].toolId.indexOf('python.generated.') === 0;
  const exposureOk: boolean = retried && inspectSolidifierExposure(
    probe.suggestedPrompts[probe.suggestedPrompts.length - 1],
    registry
  );
  aiLogInfo('[AIPhone][PythonPipelineDevice][Chain] status=' +
    (retried && ready && exposureOk ? 'passed' : 'failed') +
    ' solidifierCalls=' + probe.suggestedPrompts.length.toString() +
    ' generatedTools=' + definitions.length.toString() +
    ' ready=' + (ready ? 'true' : 'false') +
    ' exposure=' + (exposureOk ? 'true' : 'false'));
}

let pipelineStarted: boolean = false;

export async function runDemoPythonToolPipelineTest(model: LocalModel): Promise<void> {
  if (pipelineStarted) {
    return;
  }
  pipelineStarted = true;
  aiLogInfo('[AIPhone][PythonPipelineDevice] status=started');
  try {
    await runIsolatedModuleTests(model);
    await runChainedTest(model);
    aiLogInfo('[AIPhone][PythonPipelineDevice] status=completed');
  } catch (error) {
    aiLogInfo('[AIPhone][PythonPipelineDevice] status=failed error=' + `${error}`);
  }
}
