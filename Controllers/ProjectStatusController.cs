using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class ProjectStatusController(ShkrProjectStatusService projectStatusService) : ControllerBase
{
    [HttpPost("projectstatus")]
    public async Task<IActionResult> SetUserStatus(
        [FromQuery] string? projectDefinition, [FromQuery] string? userStatus, CancellationToken cancellationToken)
    {
        var result = await projectStatusService.SetUserStatusAsync(projectDefinition, userStatus, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
