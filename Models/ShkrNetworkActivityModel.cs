using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

// One activity of the batch, as SHK_INT_SAP_ACTIVITY_OB_BATCH_PRC returns it.
public sealed class NetworkActivityRow
{
    public long RecordId { get; set; }
    public string Network { get; set; } = string.Empty;
    public string Activity { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string? WbsElement { get; set; }
    public string? ControlKey { get; set; }
    public string? Plant { get; set; }
}

// Request body for Z_PS_NETWORK_SRV/NETWORKSet. All four nested collections are always sent: Gateway only routes a
// body that carries them to the deep create, and RETURNSet is the only way the SAP messages come back.
public sealed class NetworkCreateRequest
{
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("ACTIVITYSet")] public List<NetworkActivityItem> ActivitySet { get; set; } = [];
    [JsonPropertyName("RELATIONSet")] public List<object> RelationSet { get; set; } = [];
    [JsonPropertyName("ELEMENTSet")] public List<object> ElementSet { get; set; } = [];
    [JsonPropertyName("RETURNSet")] public List<object> ReturnSet { get; set; } = [];
}

// DurationNormal and WorkActivity are deliberately not part of it.
public sealed class NetworkActivityItem
{
    [JsonPropertyName("Activity")] public string Activity { get; set; } = string.Empty;
    [JsonPropertyName("Description")] public string Description { get; set; } = string.Empty;
    [JsonPropertyName("ControlKey")] public string ControlKey { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("WorkCntr")] public string WorkCntr { get; set; } = string.Empty;
    [JsonPropertyName("DurationNormalUnit")] public string DurationNormalUnit { get; set; } = string.Empty;
    [JsonPropertyName("UnWork")] public string UnWork { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;

    // NetworkActivity:ExtraActivityFields from appsettings, written as top-level properties of the activity.
    [JsonExtensionData] public Dictionary<string, object>? ExtraFields { get; set; }
}

public sealed class NetworkCreateResponse
{
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("RETURNSet")] public ODataResultSet<SapReturnMessage>? ReturnSet { get; set; }
}

// One RETURNSet row. Field carries the external id of the object the message is about and Parameter its object
// type (e.g. NetworkActivity), per the Network Create API spec.
public sealed class SapReturnMessage
{
    [JsonPropertyName("Type")] public string Type { get; set; } = string.Empty;
    [JsonPropertyName("Id")] public string Id { get; set; } = string.Empty;
    [JsonPropertyName("Number")] public string Number { get; set; } = string.Empty;
    [JsonPropertyName("Message")] public string Message { get; set; } = string.Empty;
    [JsonPropertyName("Field")] public string Field { get; set; } = string.Empty;
    [JsonPropertyName("Parameter")] public string Parameter { get; set; } = string.Empty;
    [JsonPropertyName("MessageV1")] public string MessageV1 { get; set; } = string.Empty;
    [JsonPropertyName("MessageV2")] public string MessageV2 { get; set; } = string.Empty;
    [JsonPropertyName("MessageV3")] public string MessageV3 { get; set; } = string.Empty;
    [JsonPropertyName("MessageV4")] public string MessageV4 { get; set; } = string.Empty;

    [JsonIgnore] public bool IsFailure => Type.Trim().ToUpperInvariant() is "E" or "A";

    // About this activity when Field holds the activity number - alone, or after the network number. The message
    // variables are only looked at when Parameter says the object is an activity, so a number such as a count is
    // not mistaken for an activity.
    public bool IsAbout(string network, string activity)
    {
        var candidates = new List<string> { Field };
        if (Parameter.Contains("Activity", StringComparison.OrdinalIgnoreCase))
        {
            candidates.AddRange([MessageV1, MessageV2, MessageV3, MessageV4]);
        }

        foreach (var raw in candidates)
        {
            var value = (raw ?? string.Empty).Trim();
            if (value.Length == 0)
            {
                continue;
            }

            if (SameNumber(value, activity))
            {
                return true;
            }

            if (value.Length > activity.Length && value.EndsWith(activity, StringComparison.Ordinal) &&
                SameNumber(value[..^activity.Length].TrimEnd(' ', '/', '-'), network))
            {
                return true;
            }
        }

        return false;
    }

    private static bool SameNumber(string a, string b) =>
        string.Equals(a.TrimStart('0'), b.TrimStart('0'), StringComparison.OrdinalIgnoreCase);

    public override string ToString() => $"{Type} {$"{Id}/{Number}".Trim('/')}: {Message}".Trim();
}

public sealed record NetworkActivitySyncResult(
    long BatchId, int Networks, int Activities, int Succeeded, int Failed, IReadOnlyList<string> Errors);
