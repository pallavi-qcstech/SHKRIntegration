using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class WBSController(ShkrWBSService wbsService) : ControllerBase
{
    [HttpPost("wbs")]
    public async Task<IActionResult> Sync([FromQuery] string projectCode, CancellationToken cancellationToken)
    {
        var result = await wbsService.SyncAllAsync(projectCode, cancellationToken);
        return Ok(result);
    }
}
