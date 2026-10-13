using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class SalesOrderController(ShkrSalesOrderService salesOrderService) : ControllerBase
{
    [HttpPost("salesorder")]
    public async Task<IActionResult> Sync(
        [FromQuery] DateTime? lastUpdateDate, CancellationToken cancellationToken)
    {
        var result = await salesOrderService.FetchSapDataToStagingTableAsync(lastUpdateDate, cancellationToken);
        return Ok(result);
    }
}
