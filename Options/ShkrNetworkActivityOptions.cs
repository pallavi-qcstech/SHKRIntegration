namespace SHKRIntegration.Options;

// Values sent on every activity of the PMWeb -> SAP Network Activity sync.
public sealed class ShkrNetworkActivityOptions
{
    public const string SectionName = "NetworkActivity";

    public string ControlKey { get; set; } = "PS02";

    public string Plant { get; set; } = "1010";

    // SAP INTERNAL unit code - TAG is days.
    public string DurationNormalUnit { get; set; } = "TAG";

    // EXTERNAL unit code - H is hours; Gateway converts this one.
    public string UnWork { get; set; } = "H";

    // Added to every activity as they stand, e.g. "OperationQty": "1". Empty by default. The Network Create API
    // spec says an externally processed control key (PS02) makes SAP require OperationQty and purchasing fields.
    public Dictionary<string, string> ExtraActivityFields { get; set; } = [];
}
