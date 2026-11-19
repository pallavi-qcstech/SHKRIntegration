using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class ProductHierarchyController(ShkrProductHierarchyService productHierarchyService) : ControllerBase
{
    [HttpPost("producthierarchy")]
    public async Task<IActionResult> Sync(CancellationToken cancellationToken)
    {
        var result = await productHierarchyService.FetchSapDataToStagingTableAsync(cancellationToken);
        return Ok(result);
    }
}
