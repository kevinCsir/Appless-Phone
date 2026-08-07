import {
  RuntimePythonToolRegistration,
  RuntimePythonToolRegistry,
  ToolDefinition
} from '@loop/agent-core';

export const DEMO_CURRENCY_GOAL: string =
  '帮用户计算114元的路费转化成美金是多少钱';

export const DEMO_CURRENCY_TOOL_ID: string = 'python.currency.convert.demo';

export const DEMO_CURRENCY_PYTHON_SOURCE: string = `def main(input):
    source_currency = input["sourceCurrency"]
    target_currency = input["targetCurrency"]
    amount = input["amount"]

    if source_currency == target_currency:
        result_amount = amount
    elif source_currency == "CNY" and target_currency == "USD":
        result_amount = amount / 7
    elif source_currency == "USD" and target_currency == "CNY":
        result_amount = amount * 7
    else:
        raise ValueError("Only CNY and USD are supported")

    return {"resultAmount": round(result_amount, 2)}
`;

export const DEMO_CURRENCY_TOOL_DEFINITION: ToolDefinition = JSON.parse(
  '{"toolId":"python.currency.convert.demo","domain":"finance","intent":"currency.convert",' +
    '"riskLevel":"read","backendPriority":["local_adapter"],"authModes":["none"],' +
    '"inputSchema":"sourceCurrency,targetCurrency,amount","inputJsonSchema":{"type":"object",' +
    '"description":"Convert an amount between CNY and USD using the fixed demo rate 1 USD = 7 CNY.",' +
    '"properties":{"sourceCurrency":{"type":"string","enum":["CNY","USD"],' +
    '"description":"Currency code of the original amount. Use CNY for 人民币 or 元 and USD for 美元 or 美金."},' +
    '"targetCurrency":{"type":"string","enum":["CNY","USD"],' +
    '"description":"Currency code requested for the result. Use CNY for 人民币 or 元 and USD for 美元 or 美金."},' +
    '"amount":{"type":"number","minimum":0,"description":"The original numeric amount to convert."}},' +
    '"required":["sourceCurrency","targetCurrency","amount"],"additionalProperties":false},' +
    '"outputSchema":"genericToolResults","a2uiComponent":"GenericToolResults","actions":[]}'
) as ToolDefinition;

export function registerDemoPythonCurrencyTool(registry: RuntimePythonToolRegistry): boolean {
  const registration: RuntimePythonToolRegistration = {
    scopeId: 'suggested-action-demo',
    definition: DEMO_CURRENCY_TOOL_DEFINITION,
    source: DEMO_CURRENCY_PYTHON_SOURCE
  };
  return registry.register(registration);
}
