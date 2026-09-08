using SHKRIntegration.Extensions;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddGlobalExceptionHandling();

builder.Services.AddShkrSapApiOptions(builder.Configuration);
builder.Services.AddShkrDatabaseOptions(builder.Configuration);
builder.Services.AddVendors(builder.Configuration);
builder.Services.AddProjects();

builder.Services.AddIntegrationHealthChecks();

var app = builder.Build();

app.UseExceptionHandler();

app.UseHttpsRedirection();

// No controllers, no auth: this project's only job is the daily ShkrVendorService
// (see Services/ShkrVendorService.cs) - there is no HTTP-triggerable sync endpoint,
// so there is nothing here for JWT auth or MVC routing to protect.
app.MapHealthChecks("/health");

app.Run();
