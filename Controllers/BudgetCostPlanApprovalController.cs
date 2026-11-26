using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Outbound")]
public sealed class BudgetCostPlanApprovalController(ShkrBudgetCostPlanService budgetCostPlanService) : ControllerBase
{
    public const string LegacyInboundRoute = "/SHKRIntegration/api/Inbound/budgetcost";

    [HttpPost("budgetcost")]
    [HttpPost(LegacyInboundRoute)]
    public async Task<IActionResult> Sync(
        [FromQuery] int? pmWebBudgetId, CancellationToken cancellationToken)
    {
        var result = await budgetCostPlanService.CreateAsync(pmWebBudgetId ?? 0, cancellationToken);
        return Ok(result);
    }
}
