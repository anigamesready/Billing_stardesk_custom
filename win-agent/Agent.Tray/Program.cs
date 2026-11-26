using System.Windows.Forms;

namespace AniGamesReady.Agent.Tray;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new AgentTrayForm());
    }
}
