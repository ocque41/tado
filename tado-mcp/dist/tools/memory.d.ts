export declare function tadoMemoryRead(args: {
    scope?: string;
}): Promise<string>;
export declare function tadoMemoryAppend(args: {
    text: string;
    scope?: string;
    tags?: string[];
}): Promise<string>;
export declare function tadoMemorySearch(args: {
    query: string;
    scope?: string;
}): Promise<string>;
