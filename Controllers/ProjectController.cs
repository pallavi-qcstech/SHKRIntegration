using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class ProjectController(ShkrProjectService projectService) : ControllerBase
{
    [HttpPost("project")]
    public async Task<IActionResult> Sync(
        // [FromQuery] string? projectCode,
        [FromQuery] string? createdon, CancellationToken cancellationToken)
    {
        if (!DateTime.TryParseExact(createdon, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var createdOnDate))
        {
            return BadRequest("createdon is required (yyyy-MM-dd).");
        }

        // var result = await projectService.FetchSapDataToStagingTableAsync(projectCode, createdon, cancellationToken);
        var result = await projectService.FetchSapDataToStagingTableAsync(createdOnDate, cancellationToken);
        return Ok(result);
    }
}
