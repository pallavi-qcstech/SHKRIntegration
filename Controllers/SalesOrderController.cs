using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class SalesOrderController(ShkrSalesOrderService salesOrderService) : ControllerBase
{
    [HttpPost("salesorder")]
    public async Task<IActionResult> Sync(
        [FromQuery] string? lastUpdateDate, CancellationToken cancellationToken)
    {
        if (!DateTime.TryParseExact(lastUpdateDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var lastUpdateFrom))
        {
            return BadRequest("lastUpdateDate is required (yyyy-MM-dd).");
        }

        var result = await salesOrderService.FetchSapDataToStagingTableAsync(lastUpdateFrom, cancellationToken);
        return Ok(result);
    }
}
