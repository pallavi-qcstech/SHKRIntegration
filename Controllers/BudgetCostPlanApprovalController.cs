using Microsoft.AspNetCore.Mvc;
using SHKRIntegration.Services;

namespace SHKRIntegration.Controllers;

[ApiController]
[Route("SHKRIntegration/api/Inbound")]
public sealed class BudgetCostPlanApprovalController(ShkrBudgetCostPlanService budgetCostPlanService) : ControllerBase
{
    [HttpPost("budgetcost")]
    public async Task<IActionResult> Sync(
        [FromQuery] int? pmWebBudgetId, CancellationToken cancellationToken)
    {
        var result = await budgetCostPlanService.CreateAsync(pmWebBudgetId ?? 0, cancellationToken);
        return Ok(result);
    }
}
