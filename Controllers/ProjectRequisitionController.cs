using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class ProjectRequisitionController(ShkrProjectRequisitionService projectRequisitionService) : ControllerBase
{
    [HttpPost("projectrequisition")]
    public async Task<IActionResult> Create([FromQuery] long recordId, CancellationToken cancellationToken)
    {
        var result = await projectRequisitionService.CreateAsync(recordId, cancellationToken);
        return Ok(result);
    }
}
