using Serilog;
using Serilog.Events;
using SHKRIntegration.Extensions;
using SHKRIntegration.Services;

Log.Logger = new LoggerConfiguration()
    .WriteTo.Console()
    .CreateBootstrapLogger();

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog((context, loggerConfig) =>
{
    var filePath = context.Configuration["FileLogging:Path"] ?? "logs/shkrintegration-.log";

    loggerConfig
        .MinimumLevel.Information()
        .MinimumLevel.Override("Microsoft.AspNetCore", LogEventLevel.Warning)
        .Enrich.FromLogContext()
        .WriteTo.Console()
        .WriteTo.File(
            filePath,
            rollingInterval: RollingInterval.Day,
            retainedFileCountLimit: 30,
            outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}");
});

builder.Services.AddGlobalExceptionHandling();

builder.Services.AddShkrSapApiOptions(builder.Configuration);
builder.Services.AddShkrDatabaseOptions(builder.Configuration);
builder.Services.AddVendors(builder.Configuration);
builder.Services.AddProjects();
builder.Services.AddWBS();

builder.Services.AddIntegrationHealthChecks();

var app = builder.Build();

app.UseExceptionHandler();

app.MapHealthChecks("/health");

app.MapPost("/projects/sync", async (
    ShkrProjectService projectService,
    string? projectCode,
    string? creatdon,
    ILogger<Program> logger,
    CancellationToken cancellationToken) =>
{
    var projects = await projectService.GetAllProjectsAsync(creatdon, projectCode, cancellationToken);

    logger.LogInformation("Manual project sync: {Count} project(s) fetched, staging and promoting.", projects.Count);

    var staged = 0;
    var errors = new List<string>();

    foreach (var project in projects)
    {
        try
        {
            await projectService.SaveProject(project, cancellationToken);
            staged++;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Project sync failed to stage ProjectCode {ProjectCode}.", project.ProjectCode);
            errors.Add($"{project.ProjectCode}: {ex.Message}");
        }
    }

    await projectService.RunShkrProjectsAsync(cancellationToken);

    return Results.Ok(new
    {
        fetched = projects.Count,
        staged,
        failed = errors.Count,
        errors
    });
});

app.MapPost("/wbs/sync", async (
    ShkrWBSService wbsService,
    string projectCode,
    ILogger<Program> logger,
    CancellationToken cancellationToken) =>
{
    var wbsRows = await wbsService.GetWbsHierarchyAsync(projectCode, cancellationToken);

    logger.LogInformation(
        "Manual WBS sync: {Count} WBS row(s) fetched for {ProjectCode}, staging and promoting.",
        wbsRows.Count, projectCode);

    var staged = 0;
    var errors = new List<string>();

    foreach (var wbs in wbsRows)
    {
        try
        {
            await wbsService.SaveWbs(wbs, cancellationToken);
            staged++;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "WBS sync failed to stage WBS {Wbs} for project {ProjectCode}.", wbs.Wbs, projectCode);
            errors.Add($"{wbs.Wbs}: {ex.Message}");
        }
    }

    await wbsService.RunShkrWBSAsync(cancellationToken);

    return Results.Ok(new
    {
        fetched = wbsRows.Count,
        staged,
        failed = errors.Count,
        errors
    });
});

try
{
    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "SHKRIntegration terminated unexpectedly during startup.");
}
finally
{
    Log.CloseAndFlush();
}
