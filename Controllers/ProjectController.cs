using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class ProjectController(ShkrProjectService projectService) : ControllerBase
{
    [HttpPost("project")]
    public async Task<IActionResult> Sync(
        [FromQuery] string? projectCode, [FromQuery] string? createdon, CancellationToken cancellationToken)
    {
        var result = await projectService.FetchSapDataToStagingTableAsync(projectCode, createdon, cancellationToken);
        return Ok(result);
    }
}
