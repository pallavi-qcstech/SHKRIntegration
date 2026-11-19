using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class NetworkActivityController(ShkrNetworkActivityService networkActivityService) : ControllerBase
{
    // Called daily by the PMWeb scheduler. Sends every activity not yet sent successfully to SAP.
    [HttpPost("networkactivity")]
    public async Task<IActionResult> Sync(CancellationToken cancellationToken)
    {
        var result = await networkActivityService.SyncAsync(cancellationToken);
        return Ok(result);
    }
}
