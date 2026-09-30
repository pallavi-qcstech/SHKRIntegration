using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("projects")]
public sealed class ProjectController(ShkrProjectService projectService) : ControllerBase
{
    [HttpPost("sync")]
    public async Task<IActionResult> Sync(
        [FromQuery] string? projectCode, [FromQuery] string? creatdon, CancellationToken cancellationToken)
    {
        var result = await projectService.SyncAllAsync(projectCode, creatdon, cancellationToken);
        return Ok(result);
    }
}
