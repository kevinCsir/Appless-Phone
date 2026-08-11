import { PythonToolCodeGenerationResult } from './PythonToolCodeGenerator';
import { GeneratedPythonToolContract } from './PythonToolContractGenerator';
import { RuntimePythonToolRegistry } from './RuntimePythonToolRegistry';

export function registerGeneratedPythonTool(
  registry: RuntimePythonToolRegistry,
  contract: GeneratedPythonToolContract,
  code: PythonToolCodeGenerationResult
): boolean {
  if (contract.schemaVersion !== 1 || !code.canGenerate || code.reasonCode !== '' ||
    code.source.trim().length === 0) {
    return false;
  }
  return registry.register({
    scopeId: contract.definition.toolId,
    definition: contract.definition,
    source: code.source
  });
}
