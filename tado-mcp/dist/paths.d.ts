export declare const paths: {
    globalSettings: string;
    userMemoryMarkdown: string;
    eventsCurrent: string;
};
export declare function findProjectRoot(cwd?: string): string | null;
export declare function projectConfigPath(cwd?: string): string | null;
export declare function projectLocalPath(cwd?: string): string | null;
export declare function projectMemoryPath(cwd?: string): string | null;
export declare function projectNotesDir(cwd?: string): string | null;
export declare function readJSON<T>(path: string): Promise<T | null>;
export declare function writeJSONAtomic(path: string, value: unknown): Promise<void>;
export declare function appendNDJSON(path: string, value: unknown): Promise<void>;
export declare function writeJSONSyncAtomic(path: string, value: unknown): void;
