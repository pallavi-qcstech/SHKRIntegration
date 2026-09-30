namespace SHKRIntegration.Models;

public sealed record SyncResult(int Fetched, int Staged, int Failed, IReadOnlyList<string> Errors);
