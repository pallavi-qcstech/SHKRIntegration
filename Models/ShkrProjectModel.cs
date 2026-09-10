using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace SHKRIntegration.Models;

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

public sealed class Proj
{
    [JsonPropertyName("Projectcode")] public string ProjectCode { get; set; } = string.Empty;
    [JsonPropertyName("Projectname")] public string ProjectName { get; set; } = string.Empty;
    [JsonPropertyName("Projectprofile")] public string ProjectProfile { get; set; } = string.Empty;

    [JsonPropertyName("Startdate")]
    [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? StartDate { get; set; }

    [JsonPropertyName("Creatdon")]
    [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreatedOn { get; set; }

    [JsonPropertyName("Companycode")] public string CompanyCode { get; set; } = string.Empty;
}

