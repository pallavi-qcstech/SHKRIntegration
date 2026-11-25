using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class GetPoStatusController(ShkrGetPoStatusService statusService) : ControllerBase
{
    [HttpPost("postatus")]
    public async Task<IActionResult> GetPoStatus([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await statusService.ReadPoAsync(recordId, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
