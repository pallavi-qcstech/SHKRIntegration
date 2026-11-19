using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class PrStatusController(ShkrPrStatusService statusService) : ControllerBase
{
    [HttpPost("prstatus")]
    public async Task<IActionResult> PrStatus([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await statusService.ReadPrAsync(recordId, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }

    [HttpPost("postatus")]
    public async Task<IActionResult> PoStatus([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await statusService.ReadPoAsync(recordId, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
