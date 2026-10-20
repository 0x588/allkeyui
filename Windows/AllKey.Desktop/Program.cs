using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Styling;
using AllKey.Core;
using AllKey.Desktop.Views;

namespace AllKey.Desktop;

internal static class Program
{
    internal static string[] Arguments { get; private set; } = [];
    [STAThread]
    public static int Main(string[] args)
    {
        Arguments = args;
        if (args.Contains("--verify-core")) return AllKey.Verification.VerificationSuite.RunAsync(Argument("--report")).GetAwaiter().GetResult();
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect();
    internal static string? Argument(string name)
    {
        var index = Array.IndexOf(Arguments, name);
        return index >= 0 && index + 1 < Arguments.Length ? Arguments[index + 1] : null;
    }
}

public sealed class App : Application
{
    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = ThemeVariant.Light;
    }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var directory = Program.Argument("--data-dir");
            if (directory == null && Program.Arguments.Contains("--ui-smoke"))
                directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "AllKeyUiSmoke-" + Guid.NewGuid().ToString("N"));
            var services = new AppServices(new SettingsStore(directory));
            RequestedThemeVariant = services.Settings.Current.Appearance switch
            {
                "dark" => ThemeVariant.Dark, "system" => ThemeVariant.Default, _ => ThemeVariant.Light
            };
            Ui.ApplyPalette(ActualThemeVariant == ThemeVariant.Dark);
            ActualThemeVariantChanged += (_, _) => Ui.ApplyPalette(ActualThemeVariant == ThemeVariant.Dark);
            desktop.MainWindow = new MainWindow(services);
            desktop.Exit += (_, _) => services.Dispose();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
