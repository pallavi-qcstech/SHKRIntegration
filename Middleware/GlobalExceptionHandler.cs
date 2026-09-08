using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace SHKRIntegration.Middleware;

/// 
/// Single place for every unhandled exception , so callers always get a
/// consistent application/problem+json body instead of whatever ASP.NET Core's default
/// behavior for the current environment happens to be (a bare empty 500 in Production).
/// Registered via AddExceptionHandler+AddProblemDetails / UseExceptionHandler in Program.cs.
///
/// This project has no HTTP endpoints that call into Vendor sync logic (see Program.cs), so in
/// practice the only thing likely to reach this handler is a failure in the /health request
/// path itself. Kept generic/shared infrastructure regardless: HttpRequestException and the
/// "empty response body" InvalidOperationException are what ShkrVendorService.Fetch throws on
/// an unreachable/unexpected SAP response, and SqlException is what its SaveVendor path throws
/// on a database failure - both are normally caught inside ShkrVendorService.VendorService's
/// own try/catch and logged there, not thrown up through here.

public sealed class GlobalExceptionHandler(
    IProblemDetailsService problemDetailsService,
    ILogger<GlobalExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(
        HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        if (exception is OperationCanceledException)
        {
            // Client disconnected/request aborted - not a server error, nothing to report.
            return false;
        }

        var (statusCode, title) = MapException(exception);

        logger.LogError(exception, "Unhandled exception processing {Method} {Path}",
            httpContext.Request.Method, httpContext.Request.Path);

        httpContext.Response.StatusCode = statusCode;

        var problemDetails = new ProblemDetails
        {
            Status = statusCode,
            Title = title,
            Detail = exception.Message,
            Instance = httpContext.Request.Path,
        };
        problemDetails.Extensions["traceId"] = httpContext.TraceIdentifier;

        // Writing through IProblemDetailsService (rather than a raw WriteAsJsonAsync) gets the
        // correct application/problem+json content type - matching what [ApiController]'s own
        // built-in model-validation errors already return - plus any global
        // AddProblemDetails(...) customization applied consistently.
        return await problemDetailsService.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            Exception = exception,
            ProblemDetails = problemDetails,
        });
    }

    private static (int StatusCode, string Title) MapException(Exception exception) => exception switch
    {
        ArgumentException => (StatusCodes.Status400BadRequest, "Invalid request."),
        HttpRequestException => (StatusCodes.Status502BadGateway, "Upstream SAP service call failed."),
        SqlException => (StatusCodes.Status503ServiceUnavailable, "Database is unavailable."),
        InvalidOperationException => (StatusCodes.Status502BadGateway, "Upstream service returned an unexpected response."),
        _ => (StatusCodes.Status500InternalServerError, "An unexpected error occurred."),
    };
}
