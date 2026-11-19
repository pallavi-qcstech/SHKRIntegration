using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class VendorController(ShkrVendorService vendorService) : ControllerBase
{
    [HttpPost("vendor")]
    public async Task<IActionResult> Sync(
        [FromQuery(Name = "VendorID")] string? vendorId,
        [FromQuery(Name = "Start_Date")] string? startDate,
        [FromQuery(Name = "End_Date")] string? endDate,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(startDate) || string.IsNullOrWhiteSpace(endDate))
        {
            return BadRequest("Start_Date and End_Date are required (yyyyMMdd).");
        }

        var result = await vendorService.RunFromApiAsync(vendorId, startDate, endDate, cancellationToken);

        if (result is null)
        {
            return Ok("A Vendor run is already in progress. Try again when it has finished.");
        }

        return Ok(result);
    }
}
