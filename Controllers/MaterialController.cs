using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class MaterialController(ShkrMaterialService materialService) : ControllerBase
{
    [HttpPost("material")]
    public async Task<IActionResult> Sync([FromQuery] string? materialNumber, CancellationToken cancellationToken)
    {
        var result = await materialService.FetchSapDataToStagingTableAsync(materialNumber, cancellationToken);
        return Ok(result);
    }
}
