export declare function tadoConfigGet(args: {
    scope: string;
    key: string;
}): Promise<string>;
export declare function tadoConfigSet(args: {
    scope: string;
    key: string;
    value: unknown;
}): Promise<string>;
export declare function tadoConfigList(args: {
    scope?: string;
}): Promise<string>;
