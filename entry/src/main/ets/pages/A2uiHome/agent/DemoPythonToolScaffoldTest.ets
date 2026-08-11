import {
  GeneratedPythonToolContract,
  PythonToolScaffold,
  aiLogInfo,
  generatePythonToolScaffold
} from '@loop/agent-core';

export const DEMO_TEMPERATURE_CONTRACT: GeneratedPythonToolContract = {
  schemaVersion: 1,
  definition: {
    toolId: 'python.generated.temperature.convert.scaffold.demo',
    domain: 'unit_conversion',
    intent: 'convert_temperature',
    riskLevel: 'read',
    backendPriority: ['local_adapter'],
    authModes: ['none'],
    inputSchema: 'pythonGeneratedInputV1',
    inputJsonSchema: JSON.parse(
      '{"type":"object","description":"Temperature conversion input.",' +
        '"properties":{"value":{"type":"number","description":"Temperature value."},' +
        '"fromUnit":{"type":"string","description":"Source temperature unit.",' +
        '"enum":["celsius","fahrenheit","kelvin"]},' +
        '"toUnit":{"type":"string","description":"Target temperature unit.",' +
        '"enum":["celsius","fahrenheit","kelvin"]}},' +
        '"required":["value","fromUnit","toUnit"],"additionalProperties":false}'
    ),
    outputSchema: 'genericToolResults',
    a2uiComponent: 'GenericToolResults',
    actions: []
  },
  outputJsonSchema: JSON.parse(
    '{"type":"object","description":"Temperature conversion result.",' +
      '"properties":{"result":{"type":"number","description":"Converted temperature value."}},' +
      '"required":["result"],"additionalProperties":false}'
  ),
  implementationDescription: 'Convert a temperature value from the source unit to the target unit. Support ' +
    'Celsius, Fahrenheit, and Kelvin. Use Fahrenheit = Celsius * 9/5 + 32, Celsius = ' +
    '(Fahrenheit - 32) * 5/9, Kelvin = Celsius + 273.15, and Celsius = Kelvin - 273.15. Use Celsius as an ' +
    'intermediate when needed. Return the original value when both units are identical and reject unsupported units.'
};

let demoExecuted: boolean = false;

export function runDemoPythonToolScaffoldTest(): void {
  if (demoExecuted) {
    return;
  }
  demoExecuted = true;
  try {
    const scaffold: PythonToolScaffold = generatePythonToolScaffold(DEMO_TEMPERATURE_CONTRACT);
    aiLogInfo(
      '[AIPhone][PythonToolScaffoldDemo] status=ready signature=' +
        JSON.stringify(scaffold.implementationFunctionSignature) +
        ' source=' + JSON.stringify(scaffold.placeholderSource)
    );
  } catch (error) {
    aiLogInfo('[AIPhone][PythonToolScaffoldDemo] status=failed error=' + `${error}`);
  }
}
