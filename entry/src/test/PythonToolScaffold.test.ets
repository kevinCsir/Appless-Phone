import { describe, expect, it } from '@ohos/hypium';
import {
  ConversationContext,
  LocalModel,
  LocalModelCompletionOptions,
  PythonExecutionResult,
  PythonShellCommandTransport,
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
