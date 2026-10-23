using System.Text;

namespace SHKRIntegration.Middleware;

public sealed class ShkrRequestResponseLoggingMiddleware(
    RequestDelegate next, ILogger<ShkrRequestResponseLoggingMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Request.Path.StartsWithSegments("/health"))
        {
            await next(context);
            return;
        }

        var requestBody = await ReadRequestBodyAsync(context.Request);

        logger.LogDebug(
            "PMWeb request: {Method} {Path}{NewLine}{RequestBody}",
            context.Request.Method, context.Request.Path, Environment.NewLine, requestBody);

        var originalResponseBody = context.Response.Body;
        using var responseBuffer = new MemoryStream();
        context.Response.Body = responseBuffer;

        try
        {
            await next(context);
        }
        finally
        {
            responseBuffer.Seek(0, SeekOrigin.Begin);
            var responseBytes = responseBuffer.ToArray();
            var responseBody = responseBytes.Length > 0 ? Encoding.UTF8.GetString(responseBytes) : "(empty)";

            logger.LogDebug(
                "PMWeb response: {StatusCode} for {Method} {Path}{NewLine}{ResponseBody}",
                context.Response.StatusCode, context.Request.Method, context.Request.Path, Environment.NewLine, responseBody);

            responseBuffer.Seek(0, SeekOrigin.Begin);
            await responseBuffer.CopyToAsync(originalResponseBody);
            context.Response.Body = originalResponseBody;
        }
    }

    private static async Task<string> ReadRequestBodyAsync(HttpRequest request)
    {
        if (request.ContentLength is null or 0)
        {
            return "(none)";
        }

        request.EnableBuffering();
        request.Body.Position = 0;

        using var reader = new StreamReader(request.Body, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, leaveOpen: true);
        var body = await reader.ReadToEndAsync();
        request.Body.Position = 0;

        return body;
    }
}
