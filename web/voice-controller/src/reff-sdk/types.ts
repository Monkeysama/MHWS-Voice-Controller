// SDK 类型与 Vue/Element Plus 解耦，插件可以在任意前端框架中复用。
export interface ReffErrorShape { code: string; message: string; }
export class ReffError extends Error {
  readonly code: string;
  constructor(code: string, message: string) { super(message); this.name = 'ReffError'; this.code = code; }
}
export interface ReffTransport {
  call(method: string, params?: Record<string, unknown>): Promise<unknown>;
  /** 可选的传输层清理；客户端销毁时释放消息监听和未完成请求。 */
  dispose?(): void;
}
export interface ReffSubscription { unsubscribe(): Promise<void>; }
export interface ReffClient {
  ready(): Promise<void>;
  call<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
  subscribe<T = unknown>(eventName: string, listener: (payload: T) => void): Promise<ReffSubscription>;
  dispose(): void;
}

/** 开发期热刷新轮询的清理函数。 */
export type DevReloadController = () => void;

/** 输入法焦点上报的清理函数；调用后不再监听 DOM 焦点变化。 */
export type InputFocusReporter = () => void;
