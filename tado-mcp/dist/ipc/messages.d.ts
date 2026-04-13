export interface IpcMessage {
    id: string;
    from: string;
    fromName: string;
    to: string;
    timestamp: string;
    body: string;
    status: "pending";
}
export declare function sendMessage(targetSessionID: string, body: string, fromName?: string): Promise<string>;
