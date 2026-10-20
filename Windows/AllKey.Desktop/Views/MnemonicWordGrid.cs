using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace AllKey.Desktop.Views;

internal sealed class MnemonicWordGrid : Panel
{
    internal void SetWords(string phrase, string? pattern = null)
    {
        Children.Clear();
        var words = Regex.Matches(phrase, @"\S+").Select(m => m.Value).ToArray();
        var template = Regex.Matches(pattern ?? "", @"\S+").Select(m => m.Value).ToArray();
        for (var i = 0; i < words.Length; i++)
        {
            var missing = i < template.Length && template[i] == "?";
            var content = new Grid { ColumnDefinitions = new ColumnDefinitions("18,*"), ColumnSpacing = 8 };
            content.Children.Add(Ui.Text($"{i + 1:00}", 11, Ui.Muted));
            var word = new Viewbox
            {
                Stretch = Stretch.Uniform,
                StretchDirection = StretchDirection.DownOnly,
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left,
                Child = new SelectableTextBlock { Text = words[i], FontFamily = Ui.Mono, FontSize = 16, Foreground = missing ? Ui.Accent : Ui.Ink }
            };
            Grid.SetColumn(word, 1); content.Children.Add(word);
            var cell = Ui.Panel(content);
            cell.Padding = new(10, 7); cell.CornerRadius = new(7); cell.Background = missing ? ResultRows.NeutralFill : Brush.Parse("#08263D36");
            Children.Add(cell);
        }
    }
    private static int Columns(double width) => width >= 790 ? 6 : width >= 520 ? 4 : 3;
    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsFinite(available.Width) ? available.Width : 790;
        var columns = Columns(width); var cellWidth = Math.Max(0, (width - 8 * (columns - 1)) / columns);
        foreach (var child in Children) child.Measure(new Size(cellWidth, double.PositiveInfinity));
        var rows = (Children.Count + columns - 1) / columns;
        return new Size(width, rows == 0 ? 0 : rows * Children.Max(c => c.DesiredSize.Height) + 8 * (rows - 1));
    }
    protected override Size ArrangeOverride(Size final)
    {
        var columns = Columns(final.Width); var width = Math.Max(0, (final.Width - 8 * (columns - 1)) / columns);
        var height = Children.Count == 0 ? 0 : Children.Max(c => c.DesiredSize.Height);
        for (var i = 0; i < Children.Count; i++) Children[i].Arrange(new Rect(i % columns * (width + 8), i / columns * (height + 8), width, height));
        return final;
    }
}
