using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class InvoiceController(ShkrInvoiceService invoiceService) : ControllerBase
{
    [HttpPost("invoice")]
    public async Task<IActionResult> Sync(
        [FromQuery] DateTime? lastUpdateDate, CancellationToken cancellationToken)
    {
        var result = await invoiceService.FetchSapDataToStagingTableAsync(lastUpdateDate, cancellationToken);
        return Ok(result);
    }
}
