using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class GetPrStatusController(ShkrGetPrStatusService statusService) : ControllerBase
{
    [HttpPost("prstatus")]
    public async Task<IActionResult> GetPrStatus([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await statusService.ReadPrAsync(recordId, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
