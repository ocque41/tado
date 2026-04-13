export interface SessionEntry {
    sessionID: string;
    name: string;
    engine: string;
    gridLabel: string;
    status: string;
    projectName?: string;
    agentName?: string;
    teamName?: string;
    teamID?: string;
}
export declare function getIpcRoot(): string;
export declare function readRegistry(): Promise<SessionEntry[]>;
export declare function resolveTarget(entries: SessionEntry[], target: string, projectFilter?: string, teamFilter?: string): SessionEntry | null;
