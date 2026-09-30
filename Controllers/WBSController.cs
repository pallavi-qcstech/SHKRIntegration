using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("wbs")]
public sealed class WBSController(ShkrWBSService wbsService) : ControllerBase
{
    [HttpPost("sync")]
    public async Task<IActionResult> Sync([FromQuery] string projectCode, CancellationToken cancellationToken)
    {
        var result = await wbsService.SyncAllAsync(projectCode, cancellationToken);
        return Ok(result);
    }
}
