import {
  LocalModel,
  PythonToolCodeGenerationResult,
  PythonToolCodeGenerator,
  PythonToolScaffold,
  aiLogInfo,
  generatePythonToolScaffold
} from '@loop/agent-core';
import { DEMO_TEMPERATURE_CONTRACT } from './DemoPythonToolScaffoldTest';

let demoStarted: boolean = false;

export async function runDemoPythonToolCodeGeneratorTest(model: LocalModel): Promise<void> {
  if (demoStarted) {
    return;
  }
  demoStarted = true;
  aiLogInfo('[AIPhone][PythonToolCodeGeneratorDemo] status=started');
  try {
    const scaffold: PythonToolScaffold = generatePythonToolScaffold(DEMO_TEMPERATURE_CONTRACT);
    const result: PythonToolCodeGenerationResult =
      await new PythonToolCodeGenerator(model).generate(DEMO_TEMPERATURE_CONTRACT, scaffold);
    if (!result.canGenerate) {
      aiLogInfo('[AIPhone][PythonToolCodeGeneratorDemo] status=rejected reason=' + result.reasonCode);
      return;
    }
    aiLogInfo(
      '[AIPhone][PythonToolCodeGeneratorDemo] status=ready function=' +
        JSON.stringify(result.functionSource) + ' source=' + JSON.stringify(result.source)
    );
  } catch (error) {
    aiLogInfo('[AIPhone][PythonToolCodeGeneratorDemo] status=failed error=' + `${error}`);
  }
}
