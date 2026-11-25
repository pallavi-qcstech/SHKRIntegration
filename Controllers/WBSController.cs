using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class WBSController(ShkrWBSService wbsService) : ControllerBase
{
    [HttpPost("wbs")]
    public async Task<IActionResult> Sync(
        // [FromQuery] string projectCode,
        [FromQuery] string? lastUpdateDate, CancellationToken cancellationToken)
    {
        if (!DateTime.TryParseExact(lastUpdateDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var lastUpdateFrom))
        {
            return BadRequest("lastUpdateDate is required (yyyy-MM-dd).");
        }

        // var result = await wbsService.FetchSapDataToStagingTableAsync(projectCode, cancellationToken);
        var result = await wbsService.FetchSapDataToStagingTableAsync(lastUpdateFrom, cancellationToken);
        return Ok(result);
    }
}
