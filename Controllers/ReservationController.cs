using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class ReservationController(ShkrReservationService reservationService) : ControllerBase
{
    // Called daily by the PMWeb scheduler. Without projectDefinition every active PMWeb project is read;
    // with it, only that project - useful for a rerun or a test.
    [HttpPost("reservation")]
    public async Task<IActionResult> Sync(
        [FromQuery] string? projectDefinition, CancellationToken cancellationToken)
    {
        var result = await reservationService.FetchSapDataToStagingTableAsync(projectDefinition, cancellationToken);
        return Ok(result);
    }
}
