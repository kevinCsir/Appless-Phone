import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';

const PYTHON_PATH: string = '/data/app/el1/bundle/100/hnppublic/bin/python';
const SHELL_DAEMON_HOST: string = '127.0.0.1';
const SHELL_DAEMON_PORT: number = 39527;
const CONNECT_TIMEOUT_MS: number = 2000;
const RESPONSE_TIMEOUT_MS: number = 30000;
const MAX_COMMAND_BYTES: number = 256 * 1024;
const MAX_RESPONSE_BYTES: number = 4 * 1024 * 1024;
const FRAME_HEADER_BYTES: number = 4;

export interface PythonExecutionRequest {
  source: string;
  input: Object;
}

export interface PythonExecutionError {
  type: string;
  message: string;
  traceback: string;
}

export interface PythonExecutionResult {
  ok: boolean;
  result: Object | null;
  stdout: string;
  error: PythonExecutionError | null;
}

export interface PythonProgramExecutor {
  execute(request: PythonExecutionRequest): Promise<PythonExecutionResult>;
}

export interface PythonShellCommandTransport {
  execute(command: string): Promise<string>;
}

export interface ShellDaemonPythonProgramExecutorOptions {
  pythonPath?: string;
  transport?: PythonShellCommandTransport;
}

interface ShellDaemonResponseEnvelope {
  exitCode?: number;
  output?: string;
}

interface PythonRuntimeEnvelope {
  ok?: boolean;
  result?: Object | null;
  stdout?: string;
  error?: PythonExecutionError | null;
}

function failure(type: string, message: string, traceback: string = ''): PythonExecutionResult {
  return {
    ok: false,
    result: null,
    stdout: '',
    error: {
      type,
      message,
      traceback
    }
  };
}

function errorMessage(error: Error | BusinessError | Object): string {
  if (error instanceof Error) {
    return error.message;
  }
  return `${error}`;
}

function arrayBufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function encodeFrame(payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(FRAME_HEADER_BYTES + payload.length);
  frame[0] = Math.floor(payload.length / 0x1000000) & 0xff;
  frame[1] = Math.floor(payload.length / 0x10000) & 0xff;
  frame[2] = Math.floor(payload.length / 0x100) & 0xff;
  frame[3] = payload.length & 0xff;
  frame.set(payload, FRAME_HEADER_BYTES);
  return frame;
}

class ShellDaemonFrameDecoder {
  private readonly pending: number[] = [];
  private expectedBodyBytes: number = -1;

  append(chunk: Uint8Array): Uint8Array | null {
    for (let index: number = 0; index < chunk.length; index++) {
      this.pending.push(chunk[index]);
    }
    if (this.expectedBodyBytes < 0 && this.pending.length >= FRAME_HEADER_BYTES) {
      this.expectedBodyBytes = this.pending[0] * 0x1000000 +
        this.pending[1] * 0x10000 + this.pending[2] * 0x100 + this.pending[3];
      this.pending.splice(0, FRAME_HEADER_BYTES);
      if (this.expectedBodyBytes > MAX_RESPONSE_BYTES) {
        throw new Error(
          `Shell daemon response is ${this.expectedBodyBytes} bytes; limit is ${MAX_RESPONSE_BYTES}.`
        );
      }
    }
    if (this.expectedBodyBytes < 0 || this.pending.length < this.expectedBodyBytes) {
      return null;
    }
    const body = new Uint8Array(this.expectedBodyBytes);
    for (let index: number = 0; index < this.expectedBodyBytes; index++) {
      body[index] = this.pending[index];
    }
    return body;
  }
}

class ShellDaemonPythonTransport implements PythonShellCommandTransport {
  private readonly encoder: util.TextEncoder = util.TextEncoder.create('utf-8');

  execute(command: string): Promise<string> {
    const commandBytes: Uint8Array = this.encoder.encodeInto(command);
    if (commandBytes.length === 0 || commandBytes.length > MAX_COMMAND_BYTES) {
      return Promise.reject(new Error(
        `Python shell command is ${commandBytes.length} bytes; limit is ${MAX_COMMAND_BYTES}.`
      ));
    }
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    const frame: Uint8Array = encodeFrame(commandBytes);
    const decoder = new ShellDaemonFrameDecoder();
    const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

    return new Promise<string>((resolve, reject) => {
      let settled: boolean = false;
      let timerId: number = -1;

      const closeSocket = (): void => {
        try {
          tcp.close((_error?: BusinessError): void => {
          });
        } catch (_error) {
        }
      };
      const finishWithError = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId >= 0) {
          clearTimeout(timerId);
        }
        closeSocket();
        reject(error);
      };
      const finishWithResponse = (rawResponse: string): void => {
        if (settled) {
          return;
        }
        try {
          const envelope: ShellDaemonResponseEnvelope =
            JSON.parse(rawResponse) as ShellDaemonResponseEnvelope;
          if (typeof envelope.exitCode !== 'number' || typeof envelope.output !== 'string') {
            finishWithError(new Error('Shell daemon returned an invalid response envelope.'));
            return;
          }
          if (envelope.exitCode !== 0) {
            finishWithError(new Error(
              `Python process exited with code ${envelope.exitCode}: ${envelope.output}`
            ));
            return;
          }
          settled = true;
          if (timerId >= 0) {
            clearTimeout(timerId);
          }
          closeSocket();
          resolve(envelope.output);
        } catch (error) {
          finishWithError(new Error(
            `Shell daemon response is not valid JSON: ${errorMessage(error as Object)}`
          ));
        }
      };

      tcp.on('message', (message: socket.SocketMessageInfo): void => {
        if (settled) {
          return;
        }
        try {
          const body: Uint8Array | null = decoder.append(new Uint8Array(message.message));
          if (body !== null) {
            finishWithResponse(textDecoder.decodeToString(body));
          }
        } catch (error) {
          finishWithError(new Error(errorMessage(error as Object)));
        }
      });
      tcp.on('error', (error: BusinessError): void => {
        finishWithError(new Error(`Shell daemon socket error: ${errorMessage(error)}`));
      });
      tcp.on('close', (): void => {
        finishWithError(new Error(
          'Shell daemon closed the connection before returning a complete response.'
        ));
      });

      timerId = setTimeout((): void => {
        finishWithError(new Error(
          `Shell daemon response timed out after ${RESPONSE_TIMEOUT_MS} ms; execution may continue.`
        ));
      }, RESPONSE_TIMEOUT_MS);

      const start = async (): Promise<void> => {
        await tcp.connect({
          address: {
            address: SHELL_DAEMON_HOST,
            port: SHELL_DAEMON_PORT
          },
          timeout: CONNECT_TIMEOUT_MS
        });
        await tcp.send({
          data: arrayBufferOf(frame)
        });
      };
      start().catch((error: Error | BusinessError): void => {
        finishWithError(new Error(`Shell daemon request failed: ${errorMessage(error)}`));
      });
    });
  }
}

function base64Utf8(value: string): string {
  const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(encoder.encodeInto(value));
}

function pythonBootstrap(sourceBase64: string, inputBase64: string): string {
  return [
    'import base64',
    'import contextlib',
    'import io',
    'import json',
    'import traceback',
    `_source = base64.b64decode('${sourceBase64}').decode('utf-8')`,
    `_input = json.loads(base64.b64decode('${inputBase64}').decode('utf-8'))`,
    '_stdout = io.StringIO()',
    'try:',
    '    _namespace = {}',
    '    with contextlib.redirect_stdout(_stdout):',
    "        exec(compile(_source, '<generated-python-tool>', 'exec'), _namespace)",
    "        _main = _namespace.get('main')",
    '        if not callable(_main):',
    "            raise TypeError('Python tool source must define callable main(input).')",
    '        _result = _main(_input)',
    "    _serialized = json.dumps({'ok': True, 'result': _result, " +
      "'stdout': _stdout.getvalue(), 'error': None}, ensure_ascii=False)",
    'except BaseException as _error:',
    "    _serialized = json.dumps({'ok': False, 'result': None, " +
      "'stdout': _stdout.getvalue(), 'error': {'type': type(_error).__name__, " +
      "'message': str(_error), 'traceback': traceback.format_exc()}}, ensure_ascii=False)",
    'print(_serialized)'
  ].join('\n');
}

function pythonCommand(pythonPath: string, source: string, inputJson: string): string {
  const bootstrap: string = pythonBootstrap(base64Utf8(source), base64Utf8(inputJson));
  const bootstrapBase64: string = base64Utf8(bootstrap);
  return `${pythonPath} -c "import base64;exec(base64.b64decode('${bootstrapBase64}'))"`;
}

function parsePythonResult(output: string): PythonExecutionResult {
  try {
    const envelope: PythonRuntimeEnvelope = JSON.parse(output.trim()) as PythonRuntimeEnvelope;
    if (typeof envelope.ok !== 'boolean' || typeof envelope.stdout !== 'string') {
      return failure('PYTHON_PROTOCOL_ERROR', 'Python runtime returned an invalid result envelope.');
    }
    if (envelope.ok) {
      return {
        ok: true,
        result: envelope.result === undefined ? null : envelope.result,
        stdout: envelope.stdout,
        error: null
      };
    }
    if (envelope.error === undefined || envelope.error === null ||
      typeof envelope.error.type !== 'string' ||
      typeof envelope.error.message !== 'string' ||
      typeof envelope.error.traceback !== 'string') {
      return failure('PYTHON_PROTOCOL_ERROR', 'Python runtime returned an invalid error envelope.');
    }
    return {
      ok: false,
      result: null,
      stdout: envelope.stdout,
      error: envelope.error
    };
  } catch (error) {
    return failure(
      'PYTHON_PROTOCOL_ERROR',
      `Python runtime output is not valid JSON: ${errorMessage(error as Object)}`
    );
  }
}

export class ShellDaemonPythonProgramExecutor implements PythonProgramExecutor {
  private readonly pythonPath: string;
  private readonly transport: PythonShellCommandTransport;

  constructor(options: ShellDaemonPythonProgramExecutorOptions = {}) {
    this.pythonPath = options.pythonPath === undefined ? PYTHON_PATH : options.pythonPath;
    this.transport = options.transport === undefined ?
      new ShellDaemonPythonTransport() : options.transport;
  }

  async execute(request: PythonExecutionRequest): Promise<PythonExecutionResult> {
    if (request.source.trim().length === 0) {
      return failure('INVALID_PYTHON_REQUEST', 'Python source must not be empty.');
    }
    let inputJson: string;
    try {
      inputJson = JSON.stringify(request.input);
    } catch (error) {
      return failure(
        'INVALID_PYTHON_REQUEST',
        `Python input must be JSON serializable: ${errorMessage(error as Object)}`
      );
    }
    const command: string = pythonCommand(this.pythonPath, request.source, inputJson);
    if (util.TextEncoder.create('utf-8').encodeInto(command).length > MAX_COMMAND_BYTES) {
      return failure(
        'PYTHON_REQUEST_TOO_LARGE',
        `Encoded Python request exceeds the ${MAX_COMMAND_BYTES}-byte daemon command limit.`
      );
    }
    try {
      const output: string = await this.transport.execute(command);
      return parsePythonResult(output);
    } catch (error) {
      return failure('PYTHON_RUNTIME_ERROR', errorMessage(error as Object));
    }
  }
}

export class UnavailablePythonProgramExecutor implements PythonProgramExecutor {
  execute(_request: PythonExecutionRequest): Promise<PythonExecutionResult> {
    return Promise.resolve(failure(
      'PYTHON_RUNTIME_UNAVAILABLE',
      'Python runtime is not configured.'
    ));
  }
}
