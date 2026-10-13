using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class DeliveryController(ShkrDeliveryService deliveryService) : ControllerBase
{
    [HttpPost("delivery")]
    public async Task<IActionResult> Sync(
        [FromQuery] DateTime? lastUpdateDate, CancellationToken cancellationToken)
    {
        var result = await deliveryService.FetchSapDataToStagingTableAsync(lastUpdateDate, cancellationToken);
        return Ok(result);
    }
}
