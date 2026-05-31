type JsonRpcId = number | string;

export type JsonRpcError = {
  code?: number;
  message?: string;
  data?: unknown;
};

type JsonRpcMessage = {
  id?: JsonRpcId | null;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: JsonRpcError;
};

type NotificationHandler = (method: string, params: unknown) => void;
type CloseHandler = (reason: string) => void;

export class CodexRpc {
  private nextId = 1;
  private closedByClient = false;
  private pending = new Map<
    JsonRpcId,
    {
      resolve: (value: unknown) => void;
      reject: (error: JsonRpcError) => void;
    }
  >();

  private constructor(
    private readonly socket: WebSocket,
    private readonly onNotification: NotificationHandler,
    private readonly onClose: CloseHandler,
  ) {}

  static connect(
    url: string,
    onNotification: NotificationHandler,
    onClose: CloseHandler,
  ): Promise<CodexRpc> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      let settled = false;

      socket.addEventListener(
        "open",
        () => {
          settled = true;
          const client = new CodexRpc(socket, onNotification, onClose);
          client.bind();
          resolve(client);
        },
        { once: true },
      );

      socket.addEventListener(
        "error",
        () => {
          if (!settled) reject(new Error("Could not connect to Codex."));
        },
        { once: true },
      );
    });
  }

  request<T>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));

    return new Promise((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
      });
    });
  }

  close() {
    this.closedByClient = true;
    this.rejectPending("Codex disconnected.");
    this.socket.close();
  }

  private bind() {
    this.socket.addEventListener("message", (event) => this.handleMessage(event));
    this.socket.addEventListener("close", () => {
      this.rejectPending("Codex disconnected.");
      if (!this.closedByClient) this.onClose("Codex disconnected.");
    });
  }

  private rejectPending(message: string) {
    for (const [, request] of this.pending) {
      request.reject({ message });
    }
    this.pending.clear();
  }

  private handleMessage(event: MessageEvent<string>) {
    let message: JsonRpcMessage;

    try {
      message = JSON.parse(event.data) as JsonRpcMessage;
    } catch {
      return;
    }

    if (message.id != null && ("result" in message || "error" in message)) {
      const request = this.pending.get(message.id);
      if (!request) return;

      this.pending.delete(message.id);
      if (message.error) {
        request.reject(message.error);
      } else {
        request.resolve(message.result);
      }
      return;
    }

    if (!message.method) return;

    if (message.id != null) {
      this.respondToServerRequest(message.id, message.method);
    } else {
      this.onNotification(message.method, message.params);
    }
  }

  private respondToServerRequest(id: JsonRpcId, method: string) {
    const result = defaultServerResponse(method);

    if (result === undefined) {
      this.socket.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          error: { code: -32601, message: `${method} is not supported by Modex yet.` },
        }),
      );
      return;
    }

    this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
  }
}

function defaultServerResponse(method: string): unknown {
  switch (method) {
    case "item/commandExecution/requestApproval":
      return { decision: "decline" };
    case "item/fileChange/requestApproval":
      return { decision: "decline" };
    case "item/permissions/requestApproval":
      return { permissions: {}, scope: "turn", strictAutoReview: true };
    case "item/tool/requestUserInput":
      return { answers: {} };
    case "mcpServer/elicitation/request":
      return { action: "decline", content: null, _meta: null };
    case "item/tool/call":
      return { contentItems: [], success: false };
    case "applyPatchApproval":
    case "execCommandApproval":
      return { decision: "denied" };
    default:
      return undefined;
  }
}
