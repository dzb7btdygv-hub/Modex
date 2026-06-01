import WebSocket from "@tauri-apps/plugin-websocket";

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
  private removeListener: (() => void) | null = null;
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

  static async connect(
    url: string,
    onNotification: NotificationHandler,
    onClose: CloseHandler,
  ): Promise<CodexRpc> {
    try {
      const socket = await WebSocket.connect(url);
      const client = new CodexRpc(socket, onNotification, onClose);
      client.bind();
      return client;
    } catch {
      throw new Error("Could not connect to Codex.");
    }
  }

  async request<T>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;

    const response = new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
      });
    });

    try {
      await this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    } catch (error) {
      this.pending.delete(id);
      throw error;
    }

    return response;
  }

  async close() {
    this.closedByClient = true;
    this.removeListener?.();
    this.removeListener = null;
    this.rejectPending("Codex disconnected.");
    try {
      await this.socket.disconnect();
    } catch {
    }
  }

  private bind() {
    this.removeListener = this.socket.addListener((message) => {
      if (message.type === "Text") {
        this.handleMessage(message.data);
      } else if (message.type === "Close") {
        this.handleClose();
      }
    });
  }

  private handleClose() {
    this.rejectPending("Codex disconnected.");
    if (!this.closedByClient) this.onClose("Codex disconnected.");
  }

  private rejectPending(message: string) {
    for (const [, request] of this.pending) {
      request.reject({ message });
    }
    this.pending.clear();
  }

  private handleMessage(data: string) {
    let message: JsonRpcMessage;

    try {
      message = JSON.parse(data) as JsonRpcMessage;
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
      void this.sendResponse(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          error: { code: -32601, message: `${method} is not supported by Modex yet.` },
        }),
      );
      return;
    }

    void this.sendResponse(JSON.stringify({ jsonrpc: "2.0", id, result }));
  }

  private async sendResponse(message: string) {
    try {
      await this.socket.send(message);
    } catch {
      this.handleClose();
    }
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
