using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class PurchaseOrderController(ShkrPurchaseOrderService purchaseOrderService) : ControllerBase
{
    [HttpPost("purchaseorder")]
    public async Task<IActionResult> Create([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await purchaseOrderService.CreateAsync(recordId, cancellationToken);
        return Ok(result);
    }
}
