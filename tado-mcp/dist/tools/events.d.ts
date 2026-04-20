export declare function tadoNotify(args: {
    title: string;
    body?: string;
    severity?: "info" | "success" | "warning" | "error";
}): Promise<string>;
export declare function tadoEventsQuery(args: {
    since?: string;
    type?: string;
    severity?: string;
    limit?: number;
}): Promise<string>;
