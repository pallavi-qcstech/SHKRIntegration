using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class SetProjectStatusController(ShkrSetProjectStatusService projectStatusService) : ControllerBase
{
    [HttpPost("setProjectStatus")]
    public async Task<IActionResult> SetUserStatus(
        [FromQuery] string? projectCode, [FromQuery] string? userStatus, CancellationToken cancellationToken)
    {
        var result = await projectStatusService.SetUserStatusAsync(projectCode, userStatus, cancellationToken);
        return StatusCode(result.ReplyStatusCode, result);
    }
}
