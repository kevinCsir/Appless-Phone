import { describe, expect, it } from '@ohos/hypium';
import {
  ConversationContext,
  GeneratedPythonToolContract,
  generatePythonToolScaffold,
  LocalModel,
  LocalModelCompletionOptions,
  PYTHON_TOOL_CODE_MODEL,
  PYTHON_TOOL_CONTRACT_MODEL,
  PythonExecutionResult,
  PythonShellCommandTransport,
  PythonToolCodeGenerationResult,
  PythonToolCodeGenerator,
  PythonToolScaffold,
  PythonToolContractGenerator,
  RuntimePythonToolRegistration,
  RuntimePythonToolRegistry,
  ShellDaemonPythonProgramExecutor,
  ToolDefinition,
  UnavailablePythonProgramExecutor
} from '@loop/agent-core';
import { MultiAgentSuggestedActionPreparer } from
  '../main/ets/pages/A2uiHome/agent/MultiAgentSuggestedActionPreparer';

const GENERATED_TOOL_ID: string = 'python.generated.fare_split.demo';
const GENERATED_SOURCE: string = 'def main(input):\n    return {"shares": [4268, 4266, 4266]}';
const PYTHON_PATH_FOR_TEST: string = '/data/app/el1/bundle/100/hnppublic/bin/python';

class RecordingPythonToolModel implements LocalModel {
  prompt: string = '';

  complete(
    prompt: string,
    _conversation?: ConversationContext,
    _systemPrompt?: string,
    _options?: LocalModelCompletionOptions
  ): Promise<string> {
    this.prompt = prompt;
    return Promise.resolve(
      '{"canImplement":true,"reasonCode":"","label":"Split fare","steps":[{' +
        '"stepId":"splitFare","toolId":"' + GENERATED_TOOL_ID + '","args":{' +
        '"totalCents":12800,"people":3}}]}'
    );
  }
}

class RecordingPythonContractModel implements LocalModel {
  prompt: string = '';
  options: LocalModelCompletionOptions | undefined = undefined;

  complete(
    prompt: string,
    _conversation?: ConversationContext,
    _systemPrompt?: string,
    options?: LocalModelCompletionOptions
  ): Promise<string> {
    this.prompt = prompt;
    this.options = options;
    return Promise.resolve(
      '{"canGenerate":true,"reasonCode":"","contract":{' +
        '"domain":"unit_conversion","intent":"convert_temperature",' +
        '"inputJsonSchema":{"type":"object","description":"Temperature conversion input.",' +
        '"properties":{"value":{"type":"number","description":"Temperature value."},' +
        '"fromUnit":{"type":"string","description":"Source unit."},' +
        '"toUnit":{"type":"string","description":"Target unit."}},' +
        '"required":["value","fromUnit","toUnit"],"additionalProperties":false},' +
        '"outputJsonSchema":{"type":"object","description":"Temperature conversion result.",' +
        '"properties":{"result":{"type":"number","description":"Converted value."}},' +
        '"required":["result"],"additionalProperties":false},' +
        '"implementationDescription":"Convert the value between the requested temperature units."}}'
    );
  }
}

class RecordingPythonCodeModel implements LocalModel {
  prompt: string = '';
  systemPrompt: string = '';
  options: LocalModelCompletionOptions | undefined = undefined;
  response: string;

  constructor(response: string) {
    this.response = response;
  }

  complete(
    prompt: string,
    _conversation?: ConversationContext,
    systemPrompt?: string,
    options?: LocalModelCompletionOptions
  ): Promise<string> {
    this.prompt = prompt;
    this.systemPrompt = systemPrompt ?? '';
    this.options = options;
    return Promise.resolve(this.response);
  }
}

class FallbackPythonGenerationModel implements LocalModel {
  readonly requestTags: string[] = [];
  readonly preparerPrompts: string[] = [];

  complete(
    prompt: string,
    _conversation?: ConversationContext,
    _systemPrompt?: string,
    options?: LocalModelCompletionOptions
  ): Promise<string> {
    const requestTag: string = options?.requestTag ?? '';
    this.requestTags.push(requestTag);
    if (requestTag === 'suggested-action-preparer') {
      this.preparerPrompts.push(prompt);
      if (this.preparerPrompts.length === 1) {
        return Promise.resolve(
          '{"canImplement":false,"reasonCode":"NO_SUPPORTED_TOOL","label":"","steps":[]}'
        );
      }
      const input = JSON.parse(prompt) as Record<string, Object | string>;
      const tools = input['registeredTools'] as ToolDefinition[];
      let toolId: string = '';
      for (let index: number = 0; index < tools.length; index++) {
        if (tools[index].toolId.indexOf('python.generated.') === 0) {
          toolId = tools[index].toolId;
          break;
        }
      }
      return Promise.resolve(
        '{"canImplement":true,"reasonCode":"","label":"Convert temperature","steps":[{' +
          '"stepId":"convert-temperature","toolId":' + JSON.stringify(toolId) + ',"args":{' +
          '"value":26,"sourceUnit":"celsius","targetUnit":"fahrenheit"}}]}'
      );
    }
    if (requestTag === 'python-tool-contract-generator') {
      return Promise.resolve(
        '{"canGenerate":true,"reasonCode":"","contract":{' +
          '"domain":"unit_conversion","intent":"convert_temperature",' +
          '"inputJsonSchema":{"type":"object","description":"Temperature conversion input.",' +
          '"properties":{"value":{"type":"number","description":"Temperature value."},' +
          '"sourceUnit":{"type":"string","description":"Source temperature unit.",' +
          '"enum":["celsius","fahrenheit"]},' +
          '"targetUnit":{"type":"string","description":"Target temperature unit.",' +
          '"enum":["celsius","fahrenheit"]}},' +
          '"required":["value","sourceUnit","targetUnit"],"additionalProperties":false},' +
          '"outputJsonSchema":{"type":"object","description":"Temperature conversion result.",' +
          '"properties":{"result":{"type":"number","description":"Converted temperature value."}},' +
          '"required":["result"],"additionalProperties":false},' +
          '"implementationDescription":"Convert between Celsius and Fahrenheit using the standard formulas."}}'
      );
    }
    if (requestTag === 'python-tool-code-generator') {
      return Promise.resolve(
        'def func(value, sourceUnit, targetUnit):\n' +
          '    if sourceUnit == targetUnit:\n' +
          '        return value\n' +
          '    if sourceUnit == "celsius" and targetUnit == "fahrenheit":\n' +
          '        return value * 9 / 5 + 32\n' +
          '    return (value - 32) * 5 / 9'
      );
    }
    return Promise.reject(new Error('Unexpected model request tag.'));
  }
}

class RecordingPythonShellTransport implements PythonShellCommandTransport {
  command: string = '';
  output: string;
  failureMessage: string;

  constructor(output: string, failureMessage: string = '') {
    this.output = output;
    this.failureMessage = failureMessage;
  }

  execute(command: string): Promise<string> {
    this.command = command;
    if (this.failureMessage.length > 0) {
      return Promise.reject(new Error(this.failureMessage));
    }
    return Promise.resolve(this.output);
  }
}

function generatedDefinition(toolId: string = GENERATED_TOOL_ID): ToolDefinition {
  return {
    toolId,
    domain: 'calculation',
    intent: 'fare.split',
    riskLevel: 'read',
    backendPriority: ['local_adapter'],
    authModes: ['none'],
    inputSchema: 'generatedPythonInput',
    inputJsonSchema: JSON.parse(
      '{"type":"object","properties":{"totalCents":{"type":"integer","minimum":0},' +
        '"people":{"type":"integer","minimum":1}},' +
        '"required":["totalCents","people"],"additionalProperties":false}'
    ),
    outputSchema: 'genericToolResults',
    a2uiComponent: 'GenericToolResults',
    actions: []
  };
}

function generatedRegistration(
  toolId: string = GENERATED_TOOL_ID,
  scopeId: string = 'suggested-action:demo'
): RuntimePythonToolRegistration {
  return {
    scopeId,
    definition: generatedDefinition(toolId),
    source: GENERATED_SOURCE
  };
}

export default function pythonToolScaffoldTest() {
  describe('pythonToolScaffold', () => {
    it('keeps Python source private while exposing a cloned tool definition', 0, () => {
      const registry = new RuntimePythonToolRegistry(['hotel.search']);
      expect(registry.register(generatedRegistration())).assertTrue();
      expect(registry.register(generatedRegistration())).assertFalse();
      expect(registry.register(generatedRegistration('hotel.search'))).assertFalse();

      const definitions: ToolDefinition[] = registry.definitions();
      expect(definitions.length).assertEqual(1);
      expect(definitions[0].toolId).assertEqual(GENERATED_TOOL_ID);
      expect(JSON.stringify(definitions).indexOf(GENERATED_SOURCE)).assertEqual(-1);
      expect(JSON.stringify(definitions).indexOf('suggested-action:demo')).assertEqual(-1);

      definitions[0].toolId = 'mutated';
      expect(registry.definition(GENERATED_TOOL_ID)?.toolId).assertEqual(GENERATED_TOOL_ID);
      expect(registry.registration(GENERATED_TOOL_ID)?.source).assertEqual(GENERATED_SOURCE);

      registry.removeScope('suggested-action:demo');
      expect(registry.definitions().length).assertEqual(0);
    });

    it('accepts surrounding source whitespace while rejecting blank or oversized source', 0, () => {
      const registry = new RuntimePythonToolRegistry();
      const whitespaceRegistration: RuntimePythonToolRegistration = generatedRegistration();
      whitespaceRegistration.source = '\n' + GENERATED_SOURCE + '\n';
      expect(registry.register(whitespaceRegistration)).assertTrue();
      expect(registry.registration(GENERATED_TOOL_ID)?.source)
        .assertEqual(whitespaceRegistration.source);

      const blankRegistration: RuntimePythonToolRegistration =
        generatedRegistration('python.generated.blank.demo');
      blankRegistration.source = ' \n\t ';
      expect(registry.register(blankRegistration)).assertFalse();

      const oversizedRegistration: RuntimePythonToolRegistration =
        generatedRegistration('python.generated.oversized.demo');
      oversizedRegistration.source = 'x'.repeat(131073);
      expect(registry.register(oversizedRegistration)).assertFalse();
    });

    it('makes tools registered after preparer construction visible on the next request', 0,
      async () => {
        const registry = new RuntimePythonToolRegistry();
        const model = new RecordingPythonToolModel();
        const preparer = new MultiAgentSuggestedActionPreparer(
          model,
          [],
          (): string => '2026-08-06',
          registry
        );
        expect(registry.register(generatedRegistration())).assertTrue();

        const prepared = await preparer.prepare('Split 128 yuan among 3 people');

        expect(prepared.canImplement).assertTrue();
        expect(prepared.steps.length).assertEqual(1);
        expect(prepared.steps[0].toolId).assertEqual(GENERATED_TOOL_ID);
        expect(model.prompt.indexOf(GENERATED_TOOL_ID) >= 0).assertTrue();
        expect(model.prompt.indexOf(GENERATED_SOURCE)).assertEqual(-1);
        expect(model.prompt.indexOf('suggested-action:demo')).assertEqual(-1);
      });

    it('generates a private Python tool after an unsupported plan and retries once', 0,
      async () => {
        const registry = new RuntimePythonToolRegistry();
        const model = new FallbackPythonGenerationModel();
        const preparer = new MultiAgentSuggestedActionPreparer(
          model,
          [],
          (): string => '2026-08-11',
          registry
        );

        const prepared = await preparer.prepare(
          'Convert 26 degrees Celsius to Fahrenheit'
        );

        expect(prepared.canImplement).assertTrue();
        expect(prepared.steps.length).assertEqual(1);
        expect(prepared.steps[0].toolId.indexOf('python.generated.')).assertEqual(0);
        expect(JSON.stringify(prepared.steps[0].args)).assertEqual(
          '{"value":26,"sourceUnit":"celsius","targetUnit":"fahrenheit"}'
        );
        expect(model.requestTags.join(',')).assertEqual(
          'suggested-action-preparer,python-tool-contract-generator,' +
            'python-tool-code-generator,suggested-action-preparer'
        );
        expect(model.preparerPrompts.length).assertEqual(2);
        expect(model.preparerPrompts[0].indexOf('python.generated.')).assertEqual(-1);
        expect(model.preparerPrompts[1].indexOf(prepared.steps[0].toolId) >= 0).assertTrue();
        const registration = registry.registration(prepared.steps[0].toolId);
        if (registration === null) {
          throw new Error('Expected generated Python tool registration.');
        }
        expect(registration.source.indexOf('def func(') === 0).assertTrue();
        expect(registration.source.indexOf('def main(input):') >= 0).assertTrue();
        expect(model.preparerPrompts[1].indexOf('def func(')).assertEqual(-1);
      });

    it('uses the contract generator model without changing the shared model default', 0, async () => {
      const model = new RecordingPythonContractModel();
      const result = await new PythonToolContractGenerator(
        model,
        (): string => 'python.generated.temperature.convert.test'
      ).generate('帮用户把26摄氏度的气温转化为华氏度的气温');

      expect(result.canGenerate).assertTrue();
      expect(model.options?.modelOverride).assertEqual(PYTHON_TOOL_CONTRACT_MODEL);
      expect(model.options?.modelOverride).assertEqual('qwen3.7-max');
      expect(model.options?.requestTag).assertEqual('python-tool-contract-generator');
      expect(model.options?.includeUsage).assertTrue();
      expect(model.prompt.indexOf('26摄氏度') >= 0).assertTrue();
    });

    it('generates an executable-shaped Python shell from a generated contract', 0, async () => {
      const generated = await new PythonToolContractGenerator(
        new RecordingPythonContractModel(),
        (): string => 'python.generated.temperature.convert.scaffold'
      ).generate('帮用户把26摄氏度的气温转化为华氏度的气温');
      if (generated.contract === null) {
        throw new Error('Expected a generated Python tool contract.');
      }

      const scaffold: PythonToolScaffold = generatePythonToolScaffold(generated.contract);

      expect(scaffold.implementationFunctionSignature)
        .assertEqual('def func(value, fromUnit, toUnit):');
      expect(JSON.stringify(scaffold.outputPropertyOrder)).assertEqual('["result"]');
      expect(scaffold.entrypointSource).assertEqual(
        'def main(input):\n' +
          '    value = input["value"]\n' +
          '    fromUnit = input["fromUnit"]\n' +
          '    toUnit = input["toUnit"]\n\n' +
          '    _result = func(value, fromUnit, toUnit)\n\n' +
          '    return {\n' +
          '        "result": _result\n' +
          '    }'
      );
      expect(scaffold.placeholderSource.indexOf('raise NotImplementedError') >= 0).assertTrue();
      expect(scaffold.placeholderSource.indexOf('def main(input):') >= 0).assertTrue();
    });

    it('handles optional fields, Python keywords, identifier collisions, and multiple outputs', 0, () => {
      const contract: GeneratedPythonToolContract = {
        schemaVersion: 1,
        definition: {
          toolId: 'python.generated.identifier.test',
          domain: 'test',
          intent: 'identifiers',
          riskLevel: 'read',
          backendPriority: ['local_adapter'],
          authModes: ['none'],
          inputSchema: 'pythonGeneratedInputV1',
          inputJsonSchema: JSON.parse(
            '{"type":"object","description":"Test input.","properties":{' +
              '"class":{"type":"string","description":"Required keyword."},' +
              '"a-b":{"type":"number","description":"Optional value."},' +
              '"a_b":{"type":"number","description":"Colliding optional value."}},' +
              '"required":["class"],"additionalProperties":false}'
          ),
          outputSchema: 'genericToolResults',
          a2uiComponent: 'GenericToolResults',
          actions: []
        },
        outputJsonSchema: JSON.parse(
          '{"type":"object","description":"Test output.","properties":{' +
            '"sum-value":{"type":"number","description":"Calculated sum."},' +
            '"details":{"type":"string","description":"Calculation details."}},' +
            '"required":["sum-value","details"],"additionalProperties":false}'
        ),
        implementationDescription: 'Return two test values.'
      };

      const scaffold: PythonToolScaffold = generatePythonToolScaffold(contract);

      expect(scaffold.implementationFunctionSignature)
        .assertEqual('def func(value_class, a_b, a_b_2):');
      expect(scaffold.entrypointSource.indexOf('value_class = input["class"]') >= 0).assertTrue();
      expect(scaffold.entrypointSource.indexOf('a_b = input.get("a-b")') >= 0).assertTrue();
      expect(scaffold.entrypointSource.indexOf('a_b_2 = input.get("a_b")') >= 0).assertTrue();
      expect(scaffold.entrypointSource.indexOf('_result_1, _result_2 = func(') >= 0).assertTrue();
      expect(scaffold.entrypointSource.indexOf('"sum-value": _result_1') >= 0).assertTrue();
      expect(scaffold.entrypointSource.indexOf('"details": _result_2') >= 0).assertTrue();
    });

    it('generates only func from contract and scaffold then assembles the final source', 0, async () => {
      const generated = await new PythonToolContractGenerator(
        new RecordingPythonContractModel(),
        (): string => 'python.generated.temperature.convert.code'
      ).generate('帮用户把26摄氏度的气温转化为华氏度的气温');
      if (generated.contract === null) {
        throw new Error('Expected a generated Python tool contract.');
      }
      const scaffold: PythonToolScaffold = generatePythonToolScaffold(generated.contract);
      const functionSource: string =
        'def func(value, fromUnit, toUnit):\n' +
          '    if fromUnit == "celsius" and toUnit == "fahrenheit":\n' +
          '        return value * 9 / 5 + 32\n' +
          '    raise ValueError("Unsupported conversion")';
      const model = new RecordingPythonCodeModel(functionSource);

      const result: PythonToolCodeGenerationResult =
        await new PythonToolCodeGenerator(model).generate(generated.contract, scaffold);

      expect(result.canGenerate).assertTrue();
      expect(result.functionSource).assertEqual(functionSource);
      expect(result.source).assertEqual(functionSource + '\n\n' + scaffold.entrypointSource + '\n');
      expect(model.options?.modelOverride).assertEqual(PYTHON_TOOL_CODE_MODEL);
      expect(model.options?.modelOverride).assertEqual('qwen3.7-max');
      expect(model.options?.requestTag).assertEqual('python-tool-code-generator');
      expect(model.options?.includeUsage).assertTrue();
      expect(model.prompt.indexOf('implementationDescription') >= 0).assertTrue();
      expect(model.prompt.indexOf('inputJsonSchema') >= 0).assertTrue();
      expect(model.prompt.indexOf('outputJsonSchema') >= 0).assertTrue();
      expect(model.prompt.indexOf('outputPropertyOrder') >= 0).assertTrue();
      expect(model.prompt.indexOf('26') >= 0).assertFalse();
      expect(model.systemPrompt.indexOf('exactly one complete top-level Python function') >= 0)
        .assertTrue();
    });

    it('rejects code generator output that rewrites the system main entrypoint', 0, async () => {
      const generated = await new PythonToolContractGenerator(
        new RecordingPythonContractModel(),
        (): string => 'python.generated.temperature.convert.invalid'
      ).generate('帮用户把26摄氏度的气温转化为华氏度的气温');
      if (generated.contract === null) {
        throw new Error('Expected a generated Python tool contract.');
      }
      const scaffold: PythonToolScaffold = generatePythonToolScaffold(generated.contract);
      const model = new RecordingPythonCodeModel(
        'def func(value, fromUnit, toUnit):\n' +
          '    return value\n\n' +
          'def main(input):\n' +
          '    return {}'
      );

      const result: PythonToolCodeGenerationResult =
        await new PythonToolCodeGenerator(model).generate(generated.contract, scaffold);

      expect(result.canGenerate).assertFalse();
      expect(result.reasonCode).assertEqual('INVALID_GENERATED_CODE');
      expect(result.source).assertEqual('');
    });

    it('fails closed when no Python runtime implementation is configured', 0, async () => {
      const result: PythonExecutionResult = await new UnavailablePythonProgramExecutor().execute({
        source: GENERATED_SOURCE,
        input: JSON.parse('{"totalCents":12800,"people":3}') as Object
      });

      expect(result.ok).assertFalse();
      expect(result.result === null).assertTrue();
      expect(result.stdout).assertEqual('');
      expect(result.error?.type).assertEqual('PYTHON_RUNTIME_UNAVAILABLE');
    });

    it('encodes source and input before parsing a structured Python result', 0, async () => {
      const transport = new RecordingPythonShellTransport(
        '{"ok":true,"result":{"sum":42},"stdout":"working\\n","error":null}\n'
      );
      const executor = new ShellDaemonPythonProgramExecutor({ transport });

      const result: PythonExecutionResult = await executor.execute({
        source: 'def main(input):\n    return {"sum": input["left"] + input["right"]}',
        input: JSON.parse('{"left":19,"right":23}') as Object
      });

      expect(result.ok).assertTrue();
      expect(JSON.stringify(result.result)).assertEqual('{"sum":42}');
      expect(result.stdout).assertEqual('working\n');
      expect(result.error === null).assertTrue();
      expect(transport.command.indexOf(PYTHON_PATH_FOR_TEST) === 0).assertTrue();
      expect(transport.command.indexOf('def main') >= 0).assertFalse();
      expect(transport.command.indexOf('"left":19') >= 0).assertFalse();
      expect(transport.command.indexOf('import base64') >= 0).assertTrue();
    });

    it('preserves structured Python failures and captured stdout', 0, async () => {
      const transport = new RecordingPythonShellTransport(
        '{"ok":false,"result":null,"stdout":"before failure\\n",' +
          '"error":{"type":"ValueError","message":"invalid input",' +
          '"traceback":"trace"}}'
      );
      const result: PythonExecutionResult = await new ShellDaemonPythonProgramExecutor({
        transport
      }).execute({
        source: 'def main(input):\n    raise ValueError("invalid input")',
        input: JSON.parse('{}') as Object
      });

      expect(result.ok).assertFalse();
      expect(result.stdout).assertEqual('before failure\n');
      expect(result.error?.type).assertEqual('ValueError');
      expect(result.error?.message).assertEqual('invalid input');
      expect(result.error?.traceback).assertEqual('trace');
    });

    it('maps daemon transport failures without throwing', 0, async () => {
      const transport = new RecordingPythonShellTransport('', 'daemon unavailable');
      const result: PythonExecutionResult = await new ShellDaemonPythonProgramExecutor({
        transport
      }).execute({
        source: 'def main(input):\n    return input',
        input: JSON.parse('{}') as Object
      });

      expect(result.ok).assertFalse();
      expect(result.error?.type).assertEqual('PYTHON_RUNTIME_ERROR');
      expect(result.error?.message).assertEqual('daemon unavailable');
    });
  });
}
