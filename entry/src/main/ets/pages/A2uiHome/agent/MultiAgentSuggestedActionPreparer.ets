import {
  aiLogInfo,
  generatePythonToolScaffold,
  GeneratedPythonToolContract,
  HotelSearchParseResult,
  LocalModel,
  PreparedActionDraft,
  PreparedActionDraftStep,
  PythonToolCodeGenerationResult,
  PythonToolCodeGenerator,
  PythonToolContractGenerationResult,
  PythonToolContractGenerator,
  PythonToolScaffold,
  registerGeneratedPythonTool,
  RuntimePythonToolRegistry,
  SuggestedActionPreparer,
  ToolDefinition,
  ToolInputValidationResult,
  validateToolInputValue,
  parseHotelSearchRequest
} from '@loop/agent-core';

const SUGGESTED_ACTION_SYSTEM_PROMPT: string =
  'You are the Appless Action Agent suggested-action preparer. ' +
  'Convert only the supplied natural-language goal into executable arguments using the supplied registered tool ' +
  'catalog. Every usable tool includes its real inputJsonSchema and field descriptions. Select only a tool listed ' +
  'in supportedPreparedToolIds, and make args strictly satisfy that tool inputJsonSchema. ' +
  'Return exactly one JSON object with exactly canImplement, reasonCode, label, and steps. ' +
  'Set canImplement to true only when one or more tools in supportedPreparedToolIds can together satisfy every ' +
  'constraint in the goal. Prefer the most specific registered tool that directly implements the goal; when such ' +
  'a tool exists, do not replace it with a broader web, research, social-media, or general retrieval tool. If no ' +
  'registered tool directly satisfies every required part and constraint of the goal, return canImplement=false ' +
  'instead of forcing an implementation through an unrelated or overly broad tool. Use the fewest tools that fully ' +
  'implement the goal. Return multiple steps only when ' +
  'one tool cannot fully implement the goal and each selected tool implements a distinct required part. Every step ' +
  'must be independently executable using arguments derived only from the supplied goal; do not create dependencies ' +
  'between steps. Never drop, weaken, or rewrite a goal constraint merely to produce a plan. For canImplement=true, ' +
  'reasonCode must be the empty string, label must be a concise user-facing label, and steps must contain one or ' +
  'more objects with exactly stepId, toolId, and args. Each stepId must be a unique non-empty descriptive JSON string. ' +
  'For canImplement=false, reasonCode must be one of NO_SUPPORTED_TOOL, UNSUPPORTED_CONSTRAINT, or ' +
  'UNSUPPORTED_FLOW, label must be the empty string, and steps must be an empty array. ' +
  'Use currentLocalDate only to resolve relative dates. Use schema descriptions for omitted-value defaults. ' +
  'Do not add bindings, sources, explanations, markdown, or fields absent from the selected inputJsonSchema.';

export type SuggestedActionCurrentLocalDateProvider = () => string;

interface SuggestedActionCompilerInput {
  goal: string;
  currentLocalDate: string;
  registeredTools: ToolDefinition[];
  supportedPreparedToolIds: string[];
}

function tomorrow(localDate: string): string {
  const parts: string[] = localDate.split('-');
  if (parts.length !== 3) {
    return '';
  }
  const date = new Date(Date.UTC(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])));
  if (!Number.isFinite(date.getTime())) {
    return '';
  }
  date.setUTCDate(date.getUTCDate() + 1);
  const month: string = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const day: string = date.getUTCDate().toString().padStart(2, '0');
  return date.getUTCFullYear().toString() + '-' + month + '-' + day;
}

export class MultiAgentSuggestedActionPreparer implements SuggestedActionPreparer {
  private readonly model: LocalModel;
  private readonly tools: ToolDefinition[];
  private readonly currentLocalDate: SuggestedActionCurrentLocalDateProvider;
  private readonly runtimePythonTools: RuntimePythonToolRegistry | null;
  private readonly pythonContractGenerator: PythonToolContractGenerator | null;
  private readonly pythonCodeGenerator: PythonToolCodeGenerator | null;

  constructor(
    model: LocalModel,
    tools: ToolDefinition[],
    currentLocalDate?: SuggestedActionCurrentLocalDateProvider,
    runtimePythonTools?: RuntimePythonToolRegistry
  ) {
    this.model = model;
    this.tools = tools.slice();
    this.currentLocalDate = currentLocalDate === undefined ? (): string => {
      const now = new Date();
      const month: string = (now.getMonth() + 1).toString().padStart(2, '0');
      const day: string = now.getDate().toString().padStart(2, '0');
      return now.getFullYear().toString() + '-' + month + '-' + day;
    } : currentLocalDate;
    this.runtimePythonTools = runtimePythonTools === undefined ? null : runtimePythonTools;
    this.pythonContractGenerator = this.runtimePythonTools === null ?
      null : new PythonToolContractGenerator(model);
    this.pythonCodeGenerator = this.runtimePythonTools === null ?
      null : new PythonToolCodeGenerator(model);
  }

  async prepare(
    goal: string,
    onPythonGenerationStarted?: () => void
  ): Promise<PreparedActionDraft> {
    const currentLocalDate: string = this.currentLocalDate();
    if (goal.trim().length === 0 || goal !== goal.trim() || goal.length > 240 ||
      tomorrow(currentLocalDate).length === 0) {
      throw new Error('Suggested action preparation input is invalid.');
    }
    const initial: PreparedActionDraft = await this.prepareOnce(goal, currentLocalDate);
    if (initial.canImplement) {
      return initial;
    }
    const registered: boolean = await this.generateAndRegisterPythonTool(
      goal,
      onPythonGenerationStarted
    );
    if (!registered) {
      return initial;
    }
    return this.prepareOnce(goal, currentLocalDate);
  }

  private async prepareOnce(
    goal: string,
    currentLocalDate: string
  ): Promise<PreparedActionDraft> {
    const registeredTools: ToolDefinition[] = this.supportedPreparedTools();
    const input: SuggestedActionCompilerInput = {
      goal,
      currentLocalDate,
      registeredTools,
      supportedPreparedToolIds: registeredTools.map((tool: ToolDefinition): string => tool.toolId)
    };
    const raw: string = await this.model.complete(
      JSON.stringify(input),
      undefined,
      SUGGESTED_ACTION_SYSTEM_PROMPT,
      {
        includeUsage: true,
        requestTag: 'suggested-action-preparer'
      }
    );
    const parsed: Object = JSON.parse(raw.trim()) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
      Object.keys(parsed).sort().join(',') !== 'canImplement,label,reasonCode,steps') {
      throw new Error('Suggested action preparer returned an invalid object.');
    }
    const draft: PreparedActionDraft = parsed as PreparedActionDraft;
    if (draft.canImplement === false) {
      if ((draft.reasonCode !== 'NO_SUPPORTED_TOOL' &&
        draft.reasonCode !== 'UNSUPPORTED_CONSTRAINT' &&
        draft.reasonCode !== 'UNSUPPORTED_FLOW') || draft.label !== '' ||
        !Array.isArray(draft.steps) || draft.steps.length !== 0) {
        throw new Error('Suggested action preparer returned an invalid unsupported result.');
      }
      return draft;
    }
    if (draft.canImplement !== true || draft.reasonCode !== '' ||
      typeof draft.label !== 'string' || draft.label.trim().length === 0 ||
      draft.label !== draft.label.trim() || draft.label.length > 80 ||
      !Array.isArray(draft.steps) || draft.steps.length < 1) {
      throw new Error('Suggested action preparer returned an invalid draft.');
    }
    const stepIds: string[] = [];
    for (let index = 0; index < draft.steps.length; index++) {
      const step: PreparedActionDraftStep = draft.steps[index];
      if (step === null || typeof step !== 'object' || Array.isArray(step) ||
        Object.keys(step).sort().join(',') !== 'args,stepId,toolId' ||
        typeof step.stepId !== 'string' || step.stepId.trim().length === 0 ||
        step.stepId !== step.stepId.trim() || step.stepId.length > 80 ||
        stepIds.indexOf(step.stepId) >= 0 ||
        step.args === null || typeof step.args !== 'object' || Array.isArray(step.args)) {
        throw new Error('Suggested action preparer returned an unsupported step.');
      }
      stepIds.push(step.stepId);
      const definition: ToolDefinition | null = this.supportedTool(step.toolId);
      if (definition === null || definition.inputJsonSchema === undefined) {
        return this.unsupported('NO_SUPPORTED_TOOL');
      }
      const validation: ToolInputValidationResult =
        validateToolInputValue(definition.inputJsonSchema, step.args);
      if (!validation.ok) {
        return this.unsupported('UNSUPPORTED_CONSTRAINT');
      }
      if (step.toolId === 'hotel.search') {
        const hotel: HotelSearchParseResult = parseHotelSearchRequest(step.args);
        if (!hotel.ok || hotel.value === null) {
          return this.unsupported('UNSUPPORTED_CONSTRAINT');
        }
      }
    }
    return draft;
  }

  private async generateAndRegisterPythonTool(
    goal: string,
    onStarted?: () => void
  ): Promise<boolean> {
    const registry: RuntimePythonToolRegistry | null = this.runtimePythonTools;
    const contractGenerator: PythonToolContractGenerator | null = this.pythonContractGenerator;
    const codeGenerator: PythonToolCodeGenerator | null = this.pythonCodeGenerator;
    if (registry === null || contractGenerator === null || codeGenerator === null) {
      return false;
    }
    if (onStarted !== undefined) {
      onStarted();
    }
    try {
      const contractResult: PythonToolContractGenerationResult =
        await contractGenerator.generate(goal);
      const contract: GeneratedPythonToolContract | null = contractResult.contract;
      if (!contractResult.canGenerate || contract === null) {
        aiLogInfo('[AIPhone][SuggestedAction][PythonGeneration] status=unsupported reason=' +
          contractResult.reasonCode);
        return false;
      }
      const scaffold: PythonToolScaffold = generatePythonToolScaffold(contract);
      const codeResult: PythonToolCodeGenerationResult =
        await codeGenerator.generate(contract, scaffold);
      if (!codeResult.canGenerate) {
        aiLogInfo('[AIPhone][SuggestedAction][PythonGeneration] status=failed phase=code reason=' +
          codeResult.reasonCode);
        return false;
      }
      if (!registerGeneratedPythonTool(registry, contract, codeResult)) {
        aiLogInfo('[AIPhone][SuggestedAction][PythonGeneration] status=failed phase=registration tool=' +
          contract.definition.toolId);
        return false;
      }
      aiLogInfo('[AIPhone][SuggestedAction][PythonGeneration] status=registered tool=' +
        contract.definition.toolId);
      return true;
    } catch (error) {
      aiLogInfo('[AIPhone][SuggestedAction][PythonGeneration] status=failed phase=pipeline error=' +
        `${error}`);
      return false;
    }
  }

  private supportedPreparedTools(): ToolDefinition[] {
    const definitions: ToolDefinition[] = [];
    for (let index = 0; index < this.tools.length; index++) {
      if (this.isSupportedToolDefinition(this.tools[index])) {
        definitions.push(this.tools[index]);
      }
    }
    if (this.runtimePythonTools !== null) {
      const runtimeDefinitions: ToolDefinition[] = this.runtimePythonTools.definitions();
      for (let index: number = 0; index < runtimeDefinitions.length; index++) {
        if (this.isSupportedToolDefinition(runtimeDefinitions[index]) &&
          definitions.findIndex((definition: ToolDefinition): boolean =>
            definition.toolId === runtimeDefinitions[index].toolId) < 0) {
          definitions.push(runtimeDefinitions[index]);
        }
      }
    }
    return definitions;
  }

  private supportedTool(toolId: string): ToolDefinition | null {
    for (let index = 0; index < this.tools.length; index++) {
      if (this.tools[index].toolId === toolId && this.isSupportedToolDefinition(this.tools[index])) {
        return this.tools[index];
      }
    }
    if (this.runtimePythonTools !== null) {
      const runtimeDefinition: ToolDefinition | null = this.runtimePythonTools.definition(toolId);
      if (runtimeDefinition !== null && this.isSupportedToolDefinition(runtimeDefinition)) {
        return runtimeDefinition;
      }
    }
    return null;
  }

  private isSupportedToolDefinition(definition: ToolDefinition): boolean {
    return definition.riskLevel === 'read' &&
      definition.inputJsonSchema !== undefined &&
      definition.backendPriority.length > 0 &&
      definition.backendPriority.indexOf('system_intent') < 0;
  }

  private unsupported(reasonCode: string): PreparedActionDraft {
    return {
      canImplement: false,
      reasonCode,
      label: '',
      steps: []
    };
  }
}
