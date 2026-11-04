using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class ChangeOrderController(ShkrChangeOrderService changeOrderService) : ControllerBase
{
    [HttpPost("changeorder")]
    public async Task<IActionResult> Change([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await changeOrderService.ChangeAsync(recordId, cancellationToken);
        return Ok(result);
    }
}
