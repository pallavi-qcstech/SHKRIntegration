using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class ProjectDocTypeController(ShkrProjectService projectService) : ControllerBase
{
    [HttpPost("projectdoctype")]
    public async Task<IActionResult> Sync(
        [FromQuery] string? projectCode, [FromQuery] string? creatdon, CancellationToken cancellationToken)
    {
        var result = await projectService.FetchProjectDocTypeToStagingTableAsync(projectCode, creatdon, cancellationToken);
        return Ok(result);
    }
}
