using Serilog;
using Serilog.Events;
using SHKRIntegration.Extensions;
using SHKRIntegration.Middleware;

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
        .MinimumLevel.Override("SHKRIntegration.Handlers.ShkrSapRequestResponseLoggingHandler", LogEventLevel.Debug)
        .MinimumLevel.Override("SHKRIntegration.Middleware.ShkrRequestResponseLoggingMiddleware", LogEventLevel.Debug)
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
builder.Services.AddSalesOrders();
builder.Services.AddDeliveries();
builder.Services.AddProjectRequisition();
builder.Services.AddPurchaseOrder();
builder.Services.AddReservations();

builder.Services.AddIntegrationHealthChecks();

builder.Services.AddControllers();

var app = builder.Build();

app.UseExceptionHandler();

app.UseMiddleware<ShkrRequestResponseLoggingMiddleware>();

app.MapHealthChecks("/health");

app.MapControllers();

// Startup/shutdown markers, so each deployment and app-pool recycle is visible in the log file
// (IIS does not write the framework's "Application started" lines).
app.Lifetime.ApplicationStarted.Register(() =>
{
    var entryAssembly = System.Reflection.Assembly.GetEntryAssembly();
    var version = entryAssembly?
        .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
        .FirstOrDefault()?.InformationalVersion ?? "unknown";
    var buildTime = string.IsNullOrEmpty(entryAssembly?.Location)
        ? "unknown"
        : File.GetLastWriteTime(entryAssembly.Location).ToString("yyyy-MM-dd HH:mm:ss");

    Log.Information(
        "SHKRIntegration started - Environment: {Environment}, Version: {Version}, Build: {BuildTime}, ProcessId: {ProcessId}, ContentRoot: {ContentRoot}",
        app.Environment.EnvironmentName, version, buildTime, Environment.ProcessId, app.Environment.ContentRootPath);
});

app.Lifetime.ApplicationStopping.Register(() =>
    Log.Information("SHKRIntegration stopping - ProcessId: {ProcessId}", Environment.ProcessId));

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
