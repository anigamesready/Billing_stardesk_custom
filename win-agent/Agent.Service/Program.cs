using AniGamesReady.Agent.Service;
using AniGamesReady.Agent.Shared;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

Host.CreateDefaultBuilder(args)
    .UseWindowsService(options => options.ServiceName = "Ani Games Ready StarDesk Agent")
    .ConfigureServices(services =>
    {
        services.AddSingleton<AgentApiClient>();
        services.AddHostedService<AgentWorker>();
    })
    .Build()
    .Run();
