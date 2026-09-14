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

app.MapHealthChecks("/health");

app.Run();
