using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class GetProjectStatusController(ShkrGetProjectStatusService statusService) : ControllerBase
{
    [HttpPost("getProjectStatus")]
    public async Task<IActionResult> GetProjectStatus([FromQuery] string? projectNumber, CancellationToken cancellationToken)
    {
        var result = await statusService.GetStatusAsync(projectNumber, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
