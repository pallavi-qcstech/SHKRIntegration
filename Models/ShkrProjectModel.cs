using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace SHKRIntegration.Models;

/// SAP OData v2's Edm.DateTime serializes as the ASP.NET AJAX "/Date(ms)/" format (epoch
/// milliseconds; no timezone offset observed on ZPS_PROJ_SRV). Vendor/Employee don't need this -
/// their date fields are all Edm.String in SAP-internal YYYYMMDD form, not a real Edm.DateTime.
/// Kept alongside Proj (its only user) rather than its own file - split it out again if a second
/// consumer ever needs it.
public sealed partial class ODataDateTimeConverter : JsonConverter<DateTime?>
{
    [GeneratedRegex(@"^/Date\((-?\d+)\)/$")]
    private static partial Regex DatePattern();

    public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return null;
        }

        var raw = reader.GetString();
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        var match = DatePattern().Match(raw);
        if (!match.Success)
        {
            throw new JsonException($"Unrecognized OData date format: '{raw}'.");
        }

        var epochMilliseconds = long.Parse(match.Groups[1].Value);
        return DateTimeOffset.FromUnixTimeMilliseconds(epochMilliseconds).UtcDateTime;
    }

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
    {
        if (value is null)
        {
            writer.WriteNullValue();
            return;
        }

        var epochMilliseconds = new DateTimeOffset(value.Value, TimeSpan.Zero).ToUnixTimeMilliseconds();
        writer.WriteStringValue($"/Date({epochMilliseconds})/");
    }
}

/// Shape of ZPS_PROJ_SRV/PROJSet responses. Unlike Vendor/Employee/Material, this service has no
/// "Header" wrapper entity - GET PROJSet returns the collection directly as
/// { "d": { "results": [...] } }, so ODataEnvelope&lt;ODataResultSet&lt;Proj&gt;&gt; is the whole
/// envelope; no dedicated header/request-echo class is needed.
///
/// Confirmed live 2026-09-04: 316 real projects on devfiroi. sap:pageable="false" and every
/// property is sap:filterable="false" in $metadata - there is no Start_Date/End_Date or any other
/// filter on this entity, unlike Vendor/Employee. Single-entity lookup (PROJSet('AMZ-01')) is NOT
/// implemented server-side - confirmed live, returns HTTP 501
/// "Method 'PROJSET_GET_ENTITY' not implemented in data provider class" - only the full
/// collection fetch works.
public sealed class Proj
{
    [JsonPropertyName("Projectcode")] public string ProjectCode { get; set; } = string.Empty;
    [JsonPropertyName("Projectname")] public string ProjectName { get; set; } = string.Empty;
    [JsonPropertyName("Projectprofile")] public string ProjectProfile { get; set; } = string.Empty;

    [JsonPropertyName("Startdate")]
    [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? StartDate { get; set; }

    /// SAP's own field label (see $metadata sap:label) is "Created On" - "Creatdon" here is SAP's
    /// own truncated field name, not a transcription error (same class of quirk as Employee's
    /// "Deapartment" and Material's "DEPARMENT").
    [JsonPropertyName("Creatdon")]
    [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreatedOn { get; set; }

    [JsonPropertyName("Companycode")] public string CompanyCode { get; set; } = string.Empty;
}

// ZPS_PROJ_SRV also exposes a "hierarchySet" entity (PROJECTCODE/PROJECTNAME/WBS/NAME/UP_WBS).
// Deliberately not modeled here - removed 2026-09-04. The relationship between it and PROJ is not
// actually confirmed: no Association/NavigationProperty links them in $metadata, hierarchySet
// returned zero rows live (so nothing was verified against real data), and an earlier pass named a
// class "ProjHierarchy" and described it as "a WBS parent/child tree per project" based only on
// naming-convention inference (UP_ + general SAP PS domain knowledge) and a shared PROJECTCODE
// field name - not on any confirmed evidence. Re-add only once the actual relationship is
// determined - see the investigation doc for the full reasoning this removal is based on.
